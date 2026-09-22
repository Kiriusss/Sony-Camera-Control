#import <Foundation/Foundation.h>
#include "CameraBridge.h"
#include "CameraRemote_SDK.h"
#include "CrDeviceProperty.h"
#include "CrImageDataBlock.h"
#include "CrCommandData.h"
#include "CrControlCode.h"
#include "IDeviceCallback.h"
#include "ICrCameraObjectInfo.h"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cctype>
#include <condition_variable>
#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <limits>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <thread>
#include <vector>
#include <unistd.h>

namespace {
using namespace SCRSDK;
using Clock = std::chrono::steady_clock;
class Callback;

struct State {
    std::mutex api, mutex;
    std::condition_variable changed;
    bool initialized = false, connected = false, connecting = false;
    bool configured = false, recording = false, recordingKnown = false;
    bool pendingPhoto = false, captureConfirmed = false, disconnectPending = false, liveViewPrepared = false;
    bool burstActive=false,burstDraining=false,burstReleasePending=false,burstS1Held=false;
    bool burstStopRequested=false,burstQueueComplete=false,burstTimedOut=false;
    uint64_t burstID=0,burstEventSerial=0,burstCaptured=0,burstDownloaded=0,burstFiles=0;
    int burstEmptyPolls=0;
    double burstElapsed=0,burstShutterSeconds=1;
    Clock::time_point burstStarted{},burstDeadline{},burstStopped{},burstLastEvent{},burstLastPoll{};
    std::set<std::string> burstKinds,burstSeenFiles;
    std::map<std::string,std::set<std::string>> burstGroups;
    NSString *burstStatus=@"",*burstError=@"";
    NSString *burstDirectory=@"";
    NSArray *burstModes=@[];
    bool focusIsMF=false,focusStepEnabled=false,focusPositionEnabled=false,focusPending=false;
    bool focusDriving=false,focusCancelRequested=false,focusCancelButtonHeld=false,focusTimedOut=false;
    int focusResult=0,focusMinimum=0,focusMaximum=65535,focusIncrement=1;
    uint64_t focusID=0;
    NSNumber *focusPosition=nil;
    NSArray *focusSteps=@[];
    NSString *focusStatus=@"";
    Clock::time_point focusStarted{},focusLastPoll{},focusStepUntil{},focusCancelledAt{};
    uint64_t epoch = 0, nextLog = 1;
    CrDeviceHandle handle = 0;
    ICrEnumCameraObjectInfo *enumeration = nullptr;
    Callback *callback = nullptr;
    // Retain callback addresses for the process lifetime. A late SDK callback
    // can never dereference a destroyed object; epoch checks reject old events.
    std::vector<std::unique_ptr<Callback>> callbacks;
    Clock::time_point connectStarted{}, photoStarted{}, lastLiveError{};
    std::map<std::string,Clock::time_point> lifecycleErrorTimes;
    std::set<std::string> pendingKinds;
    NSString *cameraName = @"";
    NSString *saveDirectory = @"";
    NSString *configurationError = @"";
    NSString *photoError = @"";
    NSMutableArray *logs = [NSMutableArray array];
    NSMutableArray *downloads = [NSMutableArray array];
    NSArray *cameras = @[];
    NSArray *properties = @[];
};

State &state() { static State *s = new State; return *s; }
NSString *text(const char *s) { return s ? ([NSString stringWithUTF8String:s] ?: @"") : @""; }
NSString *errorText(CrError error) {
    NSString *code=[NSString stringWithFormat:@"SDK 0x%08X", (unsigned)error];
    if(error==CrError_Connect_SessionAlreadyOpened)
        return [code stringByAppendingString:@"：相机已有遥控会话。请关闭其他相机控制程序，再断开并重新连接 USB；仍无法连接时重启相机"];
    return code;
}
NSString *decimal(uint64_t v) { return [NSString stringWithFormat:@"%llu", (unsigned long long)v]; }
bool burstBusyLocked() {auto &s=state();return s.burstActive||s.burstDraining||s.burstReleasePending;}
std::string fileKind(NSString *path) {
    NSString *extension=path.pathExtension.lowercaseString;
    if([extension isEqual:@"arw"])return "raw";
    if([extension isEqual:@"jpg"]||[extension isEqual:@"jpeg"])return "jpeg";
    if([extension isEqual:@"hif"]||[extension isEqual:@"heif"]||[extension isEqual:@"heic"])return "heif";
    return "";
}
void noteBurstActivityLocked() {
    auto &s=state();++s.burstEventSerial;s.burstLastEvent=Clock::now();s.burstEmptyPolls=0;s.burstQueueComplete=false;
}
void noteBurstFileLocked(NSString *path) {
    auto &s=state();std::string kind=fileKind(path);if(kind.empty())return;
    std::string name=path.lowercaseString.UTF8String;
    if(!s.burstSeenFiles.insert(name).second)return;
    ++s.burstFiles;noteBurstActivityLocked();
    s.burstGroups[path.stringByDeletingPathExtension.lowercaseString.UTF8String].insert(kind);
    s.burstDownloaded=0;
    for(const auto &group:s.burstGroups)
        if(std::includes(group.second.begin(),group.second.end(),s.burstKinds.begin(),s.burstKinds.end()))++s.burstDownloaded;
}
bool stopBurst(NSString **message);
void serviceBurst();
void refreshManualFocus();
void serviceManualFocus();
bool cancelManualFocus(NSString **message);
bool focusBusyLocked() {auto &s=state();return s.focusPending||s.focusDriving||s.focusCancelButtonHeld||Clock::now()<s.focusStepUntil;}
void resetManualFocusLocked() {
    auto &s=state();++s.focusID;s.focusPending=s.focusDriving=s.focusCancelButtonHeld=false;
    s.focusIsMF=s.focusStepEnabled=s.focusPositionEnabled=false;s.focusSteps=@[];
    s.focusPosition=nil;s.focusStepUntil={};s.focusStatus=@"";s.changed.notify_all();
}

// Caller owns State::mutex. SDK calls are never made under this mutex.
void logLocked(NSString *message, bool error = false) {
    auto &s = state();
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"HH:mm:ss";
    [s.logs addObject:@{@"id":@(s.nextLog++), @"time":[formatter stringFromDate:[NSDate date]],
                       @"level":error ? @"error" : @"info", @"message":message ?: @""}];
    while (s.logs.count > 200) [s.logs removeObjectAtIndex:0];
    #ifndef LR1_BRIDGE_TESTING
    // Persist SDK events for diagnosis without accessing the GUI. Never log
    // request bodies: network passwords may be present in those bodies.
    static FILE *file = nullptr;
    if (!file) {
        NSString *folder = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/LR1Control"];
        [[NSFileManager defaultManager] createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *path = [folder stringByAppendingPathComponent:@"sdk-events.log"];
        NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
        if ([attributes[NSFileSize] unsignedLongLongValue] > 4 * 1024 * 1024) {
            NSString *previous = [path stringByAppendingString:@".previous"];
            [[NSFileManager defaultManager] removeItemAtPath:previous error:nil];
            [[NSFileManager defaultManager] moveItemAtPath:path toPath:previous error:nil];
        }
        file = fopen(path.fileSystemRepresentation, "a");
    }
    if (file) {
        fprintf(file, "%s [%s] %s\n", [NSDate date].description.UTF8String, error ? "error" : "info", (message ?: @"").UTF8String);
        fflush(file);
    }
    #endif
}
void log(NSString *message, bool error = false) {
    std::lock_guard<std::mutex> lock(state().mutex); logLocked(message, error);
}
void logLifecycleError(NSString *message) {
    auto &s=state();std::lock_guard<std::mutex> lock(s.mutex);
    std::string key=(message ?: @"").UTF8String;auto now=Clock::now();
    auto previous=s.lifecycleErrorTimes.find(key);
    if(previous!=s.lifecycleErrorTimes.end() && now-previous->second<std::chrono::seconds(5))return;
    if(s.lifecycleErrorTimes.size()>=32)s.lifecycleErrorTimes.clear();
    s.lifecycleErrorTimes[key]=now;logLocked(message,true);
}

class Callback final : public IDeviceCallback {
public:
    explicit Callback(uint64_t generation) : epoch(generation) {}
    uint64_t epoch;
    std::atomic<bool> disconnected{false}, everConnected{false}, initialConnectFailed{false};
    std::map<std::string,Clock::time_point> warningTimes;
    // Caller owns State::mutex. Rate-limit identical events, not their state
    // transitions, so a repeated error still ends the relevant pending shot.
    void logEventLocked(NSString *message,bool error) {
        std::string key=message.UTF8String;auto now=Clock::now();
        auto previous=warningTimes.find(key);
        if(previous!=warningTimes.end() && now-previous->second<std::chrono::seconds(5))return;
        if(warningTimes.size()>=512)warningTimes.clear();
        warningTimes[key]=now;logLocked(message,error);
    }
    void failPhotoLocked(NSString *message) {
        auto &s=state();if(!s.pendingPhoto)return;
        if(burstBusyLocked()) {
            s.burstError=message;s.burstStatus=message;s.burstStopRequested=true;
            s.changed.notify_all();return;
        }
        s.pendingPhoto=false;s.pendingKinds.clear();s.photoError=message;
        s.changed.notify_all();
    }
    void OnConnected(DeviceConnectionVersioin) override {
        everConnected=true;
        @autoreleasepool {
            auto &s = state(); std::lock_guard<std::mutex> lock(s.mutex);
            if (epoch != s.epoch || !s.connecting) return;
            s.connected = true; s.connecting = false; s.configured = false;s.liveViewPrepared=false;
            logLocked(@"相机已连接，正在检查电脑直传设置。"); s.changed.notify_all();
        }
    }
    void OnDisconnected(CrInt32u error) override {
        disconnected = true; state().changed.notify_all();
        @autoreleasepool {
            auto &s = state(); std::lock_guard<std::mutex> lock(s.mutex);
            if (epoch != s.epoch) return;
            if (s.pendingPhoto) logLocked(@"连接中断，尚未收到全部照片文件。", true);
            s.connected = s.connecting = s.configured = s.recordingKnown = s.pendingPhoto = false;
            if(burstBusyLocked()) {
                s.burstStatus=@"连拍连接已断开，未确认全部照片回传。";
                s.burstActive=s.burstDraining=s.burstReleasePending=s.burstS1Held=false;
                ++s.burstID;s.changed.notify_all();
            }
            resetManualFocusLocked();
            s.recording = false; s.properties = @[];
            logLocked(error ? [@"相机连接已断开：" stringByAppendingString:errorText(error)] : @"相机连接已断开。", error != 0);
        }
    }
    void OnError(CrInt32u error) override {
        @autoreleasepool {
            auto &s = state(); std::lock_guard<std::mutex> lock(s.mutex);
            if (epoch != s.epoch) return;
            logLocked([@"相机报告错误：" stringByAppendingString:errorText(error)], true);
            if (s.connecting) {
                // OnError terminates the initial Connect operation. A device
                // that never connected has no disconnect event to wait for.
                if(!everConnected.load())initialConnectFailed=true;
                s.connecting = false;
            }
            s.changed.notify_all();
        }
    }
    void OnWarning(CrInt32u warning) override {
        @autoreleasepool {
            auto &s = state(); std::lock_guard<std::mutex> lock(s.mutex);
            if (epoch != s.epoch) return;
            NSString *description=@"相机通知";bool error=false,transferFailed=false;
            switch(warning) {
            case CrWarning_File_StorageFull:description=@"照片保存失败：Mac 存储空间不足";error=transferFailed=true;break;
            case CrWarning_SetFileName_Failed:description=@"照片保存失败：无法设置本地文件名";error=transferFailed=true;break;
            case CrWarning_GetImage_Failed:description=@"照片传输失败：SDK 无法取得照片文件";error=transferFailed=true;break;
            case CrWarning_NetworkErrorOccurred:description=@"相机网络连接发生错误";error=true;break;
            case CrWarning_NetworkErrorRecovered:description=@"相机网络连接已恢复";break;
            case CrWarning_Connect_Reconnecting:description=@"连接中断，等待相机重新连接";error=true;break;
            case CrWarning_Connect_Reconnected:description=@"相机已重新连接";break;
            case CrNotify_Captured_Event:
                description=@"相机已报告拍摄事件，等待照片文件";
                if(s.pendingPhoto)s.captureConfirmed=true;
                if(burstBusyLocked()){++s.burstCaptured;noteBurstActivityLocked();}
                break;
            case CrNotify_All_Download_Complete:
                description=@"SDK 已报告下载队列完成";
                if(burstBusyLocked())s.burstQueueComplete=true;
                break;
            case CrWarning_Frame_NotUpdated:description=@"实时取景画面暂未更新";break;
            case CrWarning_CautionDisplay:description=@"相机有提示信息，请查看相机画面";error=true;break;
            case CrWarning_FocusPosition_Result_OK:
                description=@"相机已结束对焦位置调整，正在读取实际位置";
                if(s.focusPending)s.focusResult=1;break;
            case CrWarning_FocusPosition_Result_NG:
                description=@"相机未完成请求的对焦位置调整";error=true;
                if(s.focusPending)s.focusResult=-1;break;
            case CrWarning_FocusPosition_Result_Invalid:
                description=@"相机不接受当前对焦位置请求";error=true;
                if(s.focusPending)s.focusResult=-2;break;
            case CrWarning_MovieRecordingOperation_Result_NG:description=@"相机录像操作失败";error=true;break;
            case CrWarning_MovieRecordingOperation_Result_Invalid:description=@"相机不接受当前录像操作";error=true;break;
            default:break;
            }
            NSString *message=[NSString stringWithFormat:@"%@（%@）。",description,errorText(warning)];
            if(transferFailed)failPhotoLocked(message);
            if (warning == CrWarning_Connect_Reconnecting) {
                s.connected = false; s.connecting = true; s.configured = false;
                s.connectStarted = Clock::now();
            }
            logEventLocked(message,error);
            s.changed.notify_all();
        }
    }
    void OnWarningExt(CrInt32u warning,CrInt32 param1,CrInt32 param2,CrInt32 param3) override {
        @autoreleasepool {
            auto &s=state();std::lock_guard<std::mutex> lock(s.mutex);
            if(epoch!=s.epoch)return;
            NSString *description=@"相机扩展通知";bool error=false,releaseFailed=false;
            if(warning==CrWarningExt_AFStatus) {
                switch(param1) {
                case CrWarningExt_AFStatusParam_Focused_AF_S:case CrWarningExt_AFStatusParam_Focused_AF_C:description=@"相机已合焦";break;
                case CrWarningExt_AFStatusParam_NotFocused_AF_S:case CrWarningExt_AFStatusParam_NotFocused_AF_C:
                    description=@"相机尚未合焦，自动对焦优先时可能不接受快门";break;
                case CrWarningExt_AFStatusParam_TrackingSubject_AF_C:description=@"相机正在连续跟踪对焦";break;
                case CrWarningExt_AFStatusParam_Unlocked:description=@"相机已释放半按对焦";break;
                default:description=@"相机自动对焦状态变化";break;
                }
                // AF may be searching during AF-C; it is not a capture failure.
            } else if(warning==CrWarningExt_OperationResults) {
                switch(param3) {
                case CrWarningExt_OperationResultsParam_OK:description=@"相机已接受操作";break;
                case CrWarningExt_OperationResultsParam_NG:description=@"相机拒绝操作";error=true;break;
                case CrWarningExt_OperationResultsParam_InvalidParameterError:description=@"相机拒绝操作：参数无效";error=true;break;
                case CrWarningExt_OperationResultsParam_CameraStatusError:description=@"相机拒绝操作：当前相机状态不允许";error=true;break;
                case CrWarningExt_OperationResultsParam_ExecuteCanceled:description=@"相机已取消操作";error=true;break;
                case CrWarningExt_OperationResultsParam_LowBrightnessError:description=@"相机操作失败：亮度过低";error=true;break;
                case CrWarningExt_OperationResultsParam_TimeLimitExceededError:description=@"相机操作超时";error=true;break;
                case CrWarningExt_OperationResultsParam_HighBrightnessError:description=@"相机操作失败：亮度过高";error=true;break;
                default:description=@"相机操作结果";break;
                }
                releaseFailed=error && param1==CrSdkApi_SendCommand &&
                    (param2==CrCommandId_Release || param2==CrCommandId_S1andRelease);
            } else if(warning==CrWarningExt_OperationInvalid) {description=@"相机报告操作无效";error=true;}
            NSString *message=[NSString stringWithFormat:@"%@（%@，参数 %d / %d / %d）。",description,errorText(warning),param1,param2,param3];
            // A rejected release with no captured event can end the pending
            // request. If exposure already occurred, retain the download wait.
            if(releaseFailed && !s.captureConfirmed)failPhotoLocked(message);
            if(error&&warning==CrWarningExt_OperationResults&&param1==CrSdkApi_SetDeviceProperty&&
               param2==CrDeviceProperty_FocusPositionSetting&&s.focusPending)s.focusResult=-1;
            if(error&&warning==CrWarningExt_OperationResults&&param1==CrSdkApi_ExecuteControlCode&&param2==CrControlCode_NearFar)
                s.focusStatus=message;
            logEventLocked(message,error);s.changed.notify_all();
        }
    }
    void OnPropertyChanged() override { state().changed.notify_all(); }
    void OnPropertyChangedCodes(CrInt32u, CrInt32u *) override { state().changed.notify_all(); }
    void OnCompleteDownload(CrChar *filename, CrInt32u) override {
        @autoreleasepool {
            auto &s = state(); std::lock_guard<std::mutex> lock(s.mutex);
            if (epoch != s.epoch || !filename) return;
            NSString *path = text(filename);
            if (![path isAbsolutePath]) path = [(burstBusyLocked()&&s.burstDirectory.length?s.burstDirectory:s.saveDirectory) stringByAppendingPathComponent:path];
            path = [path stringByStandardizingPath];
            NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
            if (![attributes[NSFileType] isEqual:NSFileTypeRegular] || [attributes[NSFileSize] unsignedLongLongValue] == 0) {
                logLocked(@"收到下载回调，但本地文件尚不可读取。", true); return;
            }
            [s.downloads addObject:@{@"path":path, @"name":path.lastPathComponent}];
            while (s.downloads.count > 200) [s.downloads removeObjectAtIndex:0];
            logLocked([@"已下载照片：" stringByAppendingString:path.lastPathComponent]);
            NSString *extension = path.pathExtension.lowercaseString;
            if(burstBusyLocked()) {
                noteBurstFileLocked(path);s.changed.notify_all();return;
            }
            if ([extension isEqual:@"arw"]) s.pendingKinds.erase("raw");
            else if ([extension isEqual:@"jpg"] || [extension isEqual:@"jpeg"]) s.pendingKinds.erase("jpeg");
            else if ([extension isEqual:@"hif"] || [extension isEqual:@"heif"] || [extension isEqual:@"heic"]) s.pendingKinds.erase("heif");
            if (s.pendingPhoto && s.pendingKinds.empty()) {
                s.pendingPhoto = false; logLocked(@"本次照片已完整下载到 Mac。");
            }
            s.changed.notify_all();
        }
    }
};

struct PropertyName { uint32_t code; const char *name; };
const PropertyName propertyNames[] = {
    {CrDeviceProperty_ExposureProgramMode,"曝光模式"}, {CrDeviceProperty_ShutterSpeed,"快门速度"},
    {CrDeviceProperty_FNumber,"光圈"}, {CrDeviceProperty_IsoSensitivity,"ISO"},
    {CrDeviceProperty_ExposureBiasCompensation,"曝光补偿"}, {CrDeviceProperty_WhiteBalance,"白平衡"},
    {CrDeviceProperty_Colortemp,"色温"}, {CrDeviceProperty_FocusMode,"对焦模式"},
    {CrDeviceProperty_FileType,"照片文件类型"}, {CrDeviceProperty_CompressionFileFormatStill,"压缩照片格式"},
    {CrDeviceProperty_StillImageQuality,"照片画质"}, {CrDeviceProperty_ImageSize,"照片尺寸"},
    {CrDeviceProperty_AspectRatio,"照片比例"}, {CrDeviceProperty_DriveMode,"拍摄模式"},
    {CrDeviceProperty_StillImageStoreDestination,"照片保存位置"}, {CrDeviceProperty_ReleaseWithoutCard,"无卡拍摄"}
};

NSString *propertyName(uint32_t code) {
    for (const auto &p : propertyNames) if (p.code == code) return text(p.name);
    return [NSString stringWithFormat:@"参数 0x%04X", code];
}
bool exposedProperty(uint32_t code) {
    for (const auto &p : propertyNames) if (p.code == code) return true;
    return false;
}
unsigned width(CrDataType type) {
    switch ((unsigned)type & 0xF) { case 1:return 1; case 2:return 2; case 3:return 4; case 4:return 8; default:return 0; }
}
uint64_t normalized(uint64_t raw, CrDataType type) {
    unsigned bytes = width(type);
    if (bytes && bytes < 8) raw &= (uint64_t(1) << (bytes*8)) - 1;
    return raw;
}
int64_t signedValue(uint64_t raw, CrDataType type) {
    raw = normalized(raw, type);
    if (((unsigned)type & CrDataType_SignBit) && width(type) < 8 && width(type) > 0) {
        unsigned bits = width(type)*8;
        if (raw & (uint64_t(1) << (bits-1))) raw |= ~((uint64_t(1) << bits)-1);
    }
    return (int64_t)raw;
}
NSString *valueString(uint64_t raw, CrDataType type) {
    if ((unsigned)type & CrDataType_SignBit) return [NSString stringWithFormat:@"%lld", (long long)signedValue(raw,type)];
    return decimal(normalized(raw,type));
}

// Identify only SDK-defined non-still modes. An unfamiliar value is not
// evidence that still capture is unavailable; its actual properties decide.
NSString *nonStillExposureLabel(uint64_t mode) {
    switch(mode) {
    case CrExposure_Movie_P:return @"视频 P 程序自动";
    case CrExposure_Movie_A:return @"视频 A 光圈优先";
    case CrExposure_Movie_S:return @"视频 S 快门优先";
    case CrExposure_Movie_M:return @"视频 M 手动";
    case CrExposure_Movie_Auto:return @"视频自动";
    case CrExposure_Movie_F:return @"视频 F";
    case CrExposure_Movie_SQMotion_P:case CrExposure_SQMotion_P:return @"S&Q 慢/快动作 P 程序自动";
    case CrExposure_Movie_SQMotion_A:case CrExposure_SQMotion_A:return @"S&Q 慢/快动作 A 光圈优先";
    case CrExposure_Movie_SQMotion_S:case CrExposure_SQMotion_S:return @"S&Q 慢/快动作 S 快门优先";
    case CrExposure_Movie_SQMotion_M:case CrExposure_SQMotion_M:return @"S&Q 慢/快动作 M 手动";
    case CrExposure_Movie_SQMotion_AUTO:return @"S&Q 慢/快动作自动";
    case CrExposure_Movie_SQMotion_F:return @"S&Q 慢/快动作 F";
    case CrExposure_HiFrameRate_P:return @"高帧率视频 P 程序自动";
    case CrExposure_HiFrameRate_A:return @"高帧率视频 A 光圈优先";
    case CrExposure_HiFrameRate_S:return @"高帧率视频 S 快门优先";
    case CrExposure_HiFrameRate_M:return @"高帧率视频 M 手动";
    case CrExposure_MOVIE:return @"视频";
    case CrExposure_F_MovieOrSQMotion:return @"视频 / S&Q F";
    case CrExposure_Movie_IntervalRec_F:return @"延时视频 F";
    case CrExposure_Movie_IntervalRec_P:return @"延时视频 P 程序自动";
    case CrExposure_Movie_IntervalRec_A:return @"延时视频 A 光圈优先";
    case CrExposure_Movie_IntervalRec_S:return @"延时视频 S 快门优先";
    case CrExposure_Movie_IntervalRec_M:return @"延时视频 M 手动";
    case CrExposure_Movie_IntervalRec_AUTO:return @"延时视频自动";
    default:return nil;
    }
}

NSString *label(uint32_t code, uint64_t value, CrDataType type) {
    switch (code) {
    case CrDeviceProperty_FNumber:
        if (value == CrFnumber_Unknown || value == CrFnumber_Nothing) return @"—";
        if (value == CrFnumber_IrisClose) return @"光圈关闭";
        return [NSString stringWithFormat:@"f/%.1f", value/100.0];
    case CrDeviceProperty_ShutterSpeed: {
        if (value == CrShutterSpeed_Bulb) return @"B 门";
        if (value == CrShutterSpeed_Nothing) return @"—";
        uint32_t numerator = (value >> 16) & 0xFFFF, denominator = value & 0xFFFF;
        if (denominator && numerator) {
            if (numerator == 1) return [NSString stringWithFormat:@"1/%u s",denominator];
            return [NSString stringWithFormat:@"%.4g s",double(numerator)/denominator];
        }
        break;
    }
    case CrDeviceProperty_IsoSensitivity:
        if ((value & 0xFFFFFF) == CrISO_AUTO) return @"自动 ISO";
        return [NSString stringWithFormat:@"ISO %llu%@", (unsigned long long)(value&0xFFFFFF), (value&0xF0000000)?@"（扩展）":@""];
    case CrDeviceProperty_ExposureBiasCompensation:
        return [NSString stringWithFormat:@"%+.1f EV", (int16_t)(value & 0xFFFF)/1000.0];
    case CrDeviceProperty_ExposureProgramMode:
        if(NSString *mode=nonStillExposureLabel(value)) return mode;
        switch (value) {
        case CrExposure_M_Manual:return @"M 手动"; case CrExposure_P_Auto:return @"P 程序自动";
        case CrExposure_A_AperturePriority:return @"A 光圈优先"; case CrExposure_S_ShutterSpeedPriority:return @"S 快门优先";
        case CrExposure_Auto:return @"自动"; case CrExposure_Auto_Plus:return @"增强自动";
        case CrExposure_STILL:return @"照片";
        default:break; } break;
    case CrDeviceProperty_WhiteBalance:
        switch(value) {
        case CrWhiteBalance_AWB:return @"自动"; case CrWhiteBalance_Daylight:return @"日光";
        case CrWhiteBalance_Shadow:return @"阴影"; case CrWhiteBalance_Cloudy:return @"阴天";
        case CrWhiteBalance_Tungsten:return @"白炽灯"; case CrWhiteBalance_Flush:return @"闪光灯";
        case CrWhiteBalance_ColorTemp:return @"色温"; case CrWhiteBalance_Custom_1:return @"自定义 1";
        case CrWhiteBalance_Custom_2:return @"自定义 2"; case CrWhiteBalance_Custom_3:return @"自定义 3";
        case CrWhiteBalance_Fluorescent_WarmWhite:return @"荧光灯 暖白";
        case CrWhiteBalance_Fluorescent_CoolWhite:return @"荧光灯 冷白";
        case CrWhiteBalance_Fluorescent_DayWhite:return @"荧光灯 日白";
        case CrWhiteBalance_Fluorescent_Daylight:return @"荧光灯 日光";
        default:break; } break;
    case CrDeviceProperty_FocusMode:
        switch(value) { case CrFocus_MF:return @"MF 手动"; case CrFocus_AF_S:return @"AF-S 单次";
        case CrFocus_AF_C:return @"AF-C 连续"; case CrFocus_AF_A:return @"AF-A 自动";
        case CrFocus_DMF:return @"DMF"; case CrFocus_AF_D:return @"AF-D"; default:break; } break;
    case CrDeviceProperty_FileType:
        switch(value) { case CrFileType_Jpeg:return @"JPEG"; case CrFileType_Raw:return @"RAW";
        case CrFileType_RawJpeg:return @"RAW + JPEG"; case CrFileType_RawHeif:return @"RAW + HEIF";
        case CrFileType_Heif:return @"HEIF"; default:break; } break;
    case CrDeviceProperty_StillImageQuality:
        switch(value) {case 1:return @"轻量";case 2:return @"标准";case 3:return @"精细";case 4:return @"超精细";default:break;} break;
    case CrDeviceProperty_ImageSize:
        switch(value) {case CrImageSize_L:return @"L 大";case CrImageSize_M:return @"M 中";
        case CrImageSize_S:return @"S 小";case CrImageSize_VGA:return @"VGA";default:break;} break;
    case CrDeviceProperty_AspectRatio:
        switch(value) {case CrAspectRatio_3_2:return @"3:2";case CrAspectRatio_16_9:return @"16:9";
        case CrAspectRatio_4_3:return @"4:3";case CrAspectRatio_1_1:return @"1:1";default:break;} break;
    case CrDeviceProperty_CompressionFileFormatStill:
        switch(value) {case CrCompressionFileFormat_JPEG:return @"JPEG";case CrCompressionFileFormat_HEIF_422:return @"HEIF 4:2:2";
        case CrCompressionFileFormat_HEIF_420:return @"HEIF 4:2:0";default:break;} break;
    case CrDeviceProperty_DriveMode:return value==CrDrive_Single?@"单张拍摄":@"相机其他拍摄模式";
    case CrDeviceProperty_StillImageStoreDestination:
        switch(value) {case CrStillImageStoreDestination_HostPC:return @"仅电脑（无需存储卡）";
        case CrStillImageStoreDestination_MemoryCard:return @"相机存储卡";
        case CrStillImageStoreDestination_HostPCAndMemoryCard:return @"电脑和存储卡";default:break;} break;
    case CrDeviceProperty_ReleaseWithoutCard:return value == CrReleaseWithoutCard_Enable ? @"允许" : @"禁止";
    case CrDeviceProperty_Still_Image_Trans_Size:return value == 0 ? @"原始尺寸" : @"小尺寸";
    case CrDeviceProperty_RAW_J_PC_Save_Image:
        switch(value) {case 0:return @"RAW 和 JPEG";case 1:return @"仅 JPEG";case 2:return @"仅 RAW";
        case 3:return @"RAW 和 HEIF";case 4:return @"仅 HEIF";default:break;} break;
    case CrDeviceProperty_Colortemp:return [NSString stringWithFormat:@"%llu K",(unsigned long long)value];
    default:break;
    }
    return valueString(value,type);
}

std::vector<uint64_t> values(const CrDeviceProperty &property) {
    std::vector<uint64_t> result;
    auto type = property.GetValueType(); unsigned bytes = width(type);
    const uint8_t *data = property.GetValues(); uint32_t size = property.GetValueSize();
    if (!bytes || !data || !size || size % bytes || size > 1024*1024) return result;
    for (uint32_t i=0;i<size/bytes;++i) { uint64_t v=0; memcpy(&v,data+i*bytes,bytes); result.push_back(v); }
    if ((unsigned)type & CrDataType_RangeBit) {
        if (result.size()!=3) return {};
        int64_t lo=signedValue(result[0],type), hi=signedValue(result[1],type), step=signedValue(result[2],type);
        if (step<=0 || hi<lo || (static_cast<long double>(hi)-lo)/step>2048) return {};
        result.clear();
        for (int64_t v=lo;v<=hi;) {
            result.push_back(normalized((uint64_t)v,type));
            if (static_cast<long double>(hi)-v<step) break;
            v+=step;
        }
    }
    return result;
}

bool readProperty(uint32_t code, CrDeviceProperty &result) {
    auto &s=state(); CrDeviceProperty *list=nullptr; CrInt32 count=0;
    CrError error=GetSelectDeviceProperties(s.handle,1,&code,&list,&count);
    bool found=false;
    if (!error && list) for (int i=0;i<count;++i) if (list[i].GetCode()==code) { result=list[i]; found=true; break; }
    if (list) ReleaseDeviceProperties(s.handle,list);
    return found && result.GetPropertyEnableFlag()!=CrEnableValue_NotSupported;
}

bool setValue(uint32_t code,uint64_t value,NSString **message,bool verify=false) {
    CrDeviceProperty p;
    if (!readProperty(code,p)) { *message=[propertyName(code) stringByAppendingString:@"：相机未提供此参数。"]; return false; }
    value=normalized(value,p.GetValueType());
    if (p.IsGetEnableCurrentValue() && normalized(p.GetCurrentValue(),p.GetValueType())==value) return true;
    if (!p.IsSetEnableCurrentValue()) { *message=[propertyName(code) stringByAppendingString:@"：当前模式不能修改。"]; return false; }
    auto allowed=values(p);
    if (((unsigned)p.GetValueType() & (CrDataType_ArrayBit|CrDataType_RangeBit)) &&
        (allowed.empty() || std::find(allowed.begin(),allowed.end(),value)==allowed.end())) {
        *message=[propertyName(code) stringByAppendingString:@"：该值不在相机当前可用选项中。"]; return false;
    }
    p.SetCurrentValue(value); CrError error=SetDeviceProperty(state().handle,&p);
    if (error) { *message=[NSString stringWithFormat:@"%@设置失败：%@",propertyName(code),errorText(error)]; return false; }
    if (verify) {
        auto deadline=Clock::now()+std::chrono::seconds(5);
        do {
            std::this_thread::sleep_for(std::chrono::milliseconds(60));
            CrDeviceProperty current;
            if (readProperty(code,current) && current.IsGetEnableCurrentValue() &&
                normalized(current.GetCurrentValue(),current.GetValueType())==value) return true;
        } while (Clock::now()<deadline);
        *message=[propertyName(code) stringByAppendingString:@"：未收到相机状态确认。"]; return false;
    }
    return true;
}

// Parse ranges directly: the absolute lens position range has 65536 values.
// Expanding it through the menu helper would incorrectly disable this control.
bool numericRange(CrDataType type,const uint8_t *data,uint32_t size,int64_t &lo,int64_t &hi,int64_t &increment) {
    unsigned bytes=width(type);
    if(!(type&CrDataType_RangeBit)||!bytes||bytes>8||!data||size!=3*bytes)return false;
    uint64_t raw[3]={};for(int i=0;i<3;++i)memcpy(&raw[i],data+i*bytes,bytes);
    lo=signedValue(raw[0],type);hi=signedValue(raw[1],type);increment=signedValue(raw[2],type);
    return increment>0&&hi>=lo;
}
bool inRange(int64_t value,int64_t lo,int64_t hi,int64_t increment) {
    return value>=lo&&value<=hi&&increment>0&&(value-lo)%increment==0;
}
bool nearFarRange(int64_t &lo,int64_t &hi,int64_t &increment) {
    CrDeviceProperty enable;
    if(!readProperty(CrDeviceProperty_NearFar,enable)||!enable.IsGetEnableCurrentValue()||enable.GetCurrentValue()!=CrNearFar_Enable)return false;
    CrControlCodeInfo *info=nullptr;
    CrError error=GetSelectControlCode(state().handle,CrControlCode_NearFar,&info);
    bool ok=!error&&info&&info->GetCode()==CrControlCode_NearFar&&info->GetValueType()==CrDataType_Int16Range&&
        numericRange(info->GetValueType(),info->GetValues(),info->GetValueSize(),lo,hi,increment);
    if(info)ReleaseControlCodes(state().handle,info);
    return ok;
}
bool cancelFocusSupported() {
    CrControlCodeInfo *info=nullptr;
    CrError error=GetSelectControlCode(state().handle,CrControlCode_CancelFocusPosition,&info);
    bool ok=!error&&info&&info->GetCode()==CrControlCode_CancelFocusPosition&&info->GetValueType()==CrDataType_Button;
    if(info)ReleaseControlCodes(state().handle,info);
    return ok;
}
void refreshManualFocus() {
    auto &s=state();
    {std::lock_guard<std::mutex> lock(s.mutex);if(!s.connected||!s.handle)return;}
    CrDeviceProperty mode,current,position,driving;
    bool isMF=readProperty(CrDeviceProperty_FocusMode,mode)&&mode.IsGetEnableCurrentValue()&&mode.GetCurrentValue()==CrFocus_MF;
    NSNumber *actual=readProperty(CrDeviceProperty_FocusPositionCurrentValue,current)&&current.IsGetEnableCurrentValue()&&current.GetCurrentValue()<=65535?@(current.GetCurrentValue()):nil;
    bool isDriving=readProperty(CrDeviceProperty_FocusDrivingStatus,driving)&&driving.IsGetEnableCurrentValue()&&driving.GetCurrentValue()==CrFocusDrivingStatus_Driving;
    int64_t lo=0,hi=65535,increment=1;
    bool positionOK=isMF&&actual&&readProperty(CrDeviceProperty_FocusPositionSetting,position)&&position.IsSetEnableCurrentValue()&&
        position.GetValueType()==CrDataType_UInt16Range&&numericRange(position.GetValueType(),position.GetValues(),position.GetValueSize(),lo,hi,increment)&&lo>=0&&hi<=65535;
    int64_t stepLo=0,stepHi=0,stepIncrement=0;NSMutableArray *steps=[NSMutableArray array];
    if(isMF&&nearFarRange(stepLo,stepHi,stepIncrement))
        for(int n:{1,3,7})if(inRange(n,stepLo,stepHi,stepIncrement)&&inRange(-n,stepLo,stepHi,stepIncrement))[steps addObject:@(n)];
    std::lock_guard<std::mutex> lock(s.mutex);
    s.focusIsMF=isMF;s.focusPosition=actual;s.focusPositionEnabled=positionOK;s.focusStepEnabled=steps.count>0;s.focusSteps=[steps copy];
    s.focusMinimum=(int)lo;s.focusMaximum=(int)hi;s.focusIncrement=(int)increment;s.focusDriving=isDriving;
}
bool cancelManualFocus(NSString **message) {
    auto &s=state();bool held;
    {std::lock_guard<std::mutex> lock(s.mutex);held=s.focusCancelButtonHeld;
     if(!s.focusPending&&!s.focusDriving&&!held){*message=@"当前没有待取消的绝对位置调整。";return true;}}
    if(!held&&!cancelFocusSupported()){*message=@"相机当前不提供取消绝对对焦位置操作；正在读取镜头状态。";return false;}
    CrError down=0;
    if(!held) {
        {std::lock_guard<std::mutex> lock(s.mutex);s.focusCancelButtonHeld=true;}
        down=SendCommand(s.handle,CrCommandId_CancelFocusPosition,CrCommandParam_Down);
        std::this_thread::sleep_for(std::chrono::milliseconds(35));
    }
    // Always release the button even when Down returned an error.
    CrError up=SendCommand(s.handle,CrCommandId_CancelFocusPosition,CrCommandParam_Up);
    if(up)up=SendCommand(s.handle,CrCommandId_CancelFocusPosition,CrCommandParam_Up);
    {std::lock_guard<std::mutex> lock(s.mutex);
     s.focusCancelButtonHeld=up!=0;
     if(!down&&!up){s.focusCancelRequested=true;s.focusCancelledAt=Clock::now();s.focusStatus=@"已提交停止对焦，等待镜头停止及实际位置。";}}
    if(down||up){*message=[@"取消对焦请求未完成：" stringByAppendingString:errorText(down?down:up)];return false;}
    *message=@"已提交停止对焦，等待相机确认。";return true;
}
void serviceManualFocus() {
    auto &s=state();uint64_t id;bool timeout=false,retryUp=false;
    {std::lock_guard<std::mutex> lock(s.mutex);
     if(!s.connected||!s.handle||!s.focusPending)return;
     auto now=Clock::now();if(now-s.focusLastPoll<std::chrono::milliseconds(100))return;
     s.focusLastPoll=now;id=s.focusID;retryUp=s.focusCancelButtonHeld;
     timeout=!s.focusTimedOut&&now-s.focusStarted>std::chrono::seconds(15);
     if(timeout){s.focusTimedOut=true;s.focusStatus=@"对焦位置调整等待超时，正在停止并读取实际位置。";logLocked(s.focusStatus,true);}}
    if(timeout||retryUp){NSString *message=@"";if(!cancelManualFocus(&message))logLifecycleError(message);}
    CrDeviceProperty current,driving;
    bool actualKnown=readProperty(CrDeviceProperty_FocusPositionCurrentValue,current)&&current.IsGetEnableCurrentValue()&&current.GetCurrentValue()<=65535;
    bool drivingKnown=readProperty(CrDeviceProperty_FocusDrivingStatus,driving)&&driving.IsGetEnableCurrentValue()&&
        (driving.GetCurrentValue()==CrFocusDrivingStatus_Driving||driving.GetCurrentValue()==CrFocusDrivingStatus_NotDriving);
    std::lock_guard<std::mutex> lock(s.mutex);
    if(id!=s.focusID||!s.focusPending)return;
    s.focusPosition=actualKnown?@(current.GetCurrentValue()):nil;
    if(drivingKnown)s.focusDriving=driving.GetCurrentValue()==CrFocusDrivingStatus_Driving;
    bool idle=drivingKnown&&!s.focusDriving;
    // A fresh actual-position read and the camera's result/idle state decide
    // completion. The requested position is never substituted for readback.
    bool cancelled=s.focusCancelRequested&&Clock::now()-s.focusCancelledAt>std::chrono::milliseconds(250)&&idle;
    bool terminal=s.focusResult!=0&&(!drivingKnown||idle);
    bool timedOutIdle=s.focusTimedOut&&idle&&Clock::now()-s.focusStarted>std::chrono::seconds(16);
    if(actualKnown&&!s.focusCancelButtonHeld&&(terminal||cancelled||timedOutIdle)) {
        s.focusPending=false;
        if(s.focusTimedOut)s.focusStatus=@"对焦请求超时；镜头已停止。";
        else if(s.focusCancelRequested)s.focusStatus=@"对焦已停止。";
        else if(s.focusResult>0)s.focusStatus=@"位置调整已结束。";
        else s.focusStatus=@"相机未完成位置调整。";
        logLocked(s.focusStatus,s.focusTimedOut||s.focusResult<0);s.changed.notify_all();
    }
}
void monitorManualFocus(uint64_t epoch,uint64_t id) {
    @autoreleasepool {
        auto &s=state();
        for(;;) {
            {std::unique_lock<std::mutex> lock(s.mutex);
             if(epoch!=s.epoch||id!=s.focusID||!s.focusPending)return;
             s.changed.wait_for(lock,std::chrono::milliseconds(100));}
            std::lock_guard<std::mutex> serial(s.api);
            {std::lock_guard<std::mutex> lock(s.mutex);if(epoch!=s.epoch||id!=s.focusID||!s.focusPending)return;}
            serviceManualFocus();
        }
    }
}
bool integerArgument(id object,int64_t &value) {
    if(![object isKindOfClass:NSNumber.class])return false;
    double number=[object doubleValue];
    if(!std::isfinite(number)||number<-65535||number>65535||number!=std::trunc(number))return false;
    value=[object longLongValue];return true;
}

// Keep S1 held until S2 is released. Cleanup also runs on every early return.
struct HalfPress {
    bool held=false;
    bool release(NSString **message) {
        if(!held)return true;
        if(!setValue(CrDeviceProperty_S1,CrLockIndicator_Unlocked,message,false))return false;
        held=false;return true;
    }
    ~HalfPress() {
        if(!held)return;
        @try {
            try {NSString *message=@"";if(!release(&message))log([@"释放半按对焦失败：" stringByAppendingString:message],true);}
            catch(...) {log(@"释放半按对焦时发生错误。",true);}
        } @catch(NSException *) {}
    }
};

bool lockAndWaitForFocus(HalfPress &halfPress,NSString **message) {
    halfPress.held=true; // Even a failed Set can require an unlock attempt.
    if(!setValue(CrDeviceProperty_S1,CrLockIndicator_Locked,message,false))return false;
    auto deadline=Clock::now()+std::chrono::seconds(3);
    do {
        std::this_thread::sleep_for(std::chrono::milliseconds(60));
        {std::lock_guard<std::mutex> lock(state().mutex);if(!state().connected){*message=@"对焦期间相机已断开。";return false;}}
        CrDeviceProperty focus;
        if(readProperty(CrDeviceProperty_FocusIndication,focus) && focus.IsGetEnableCurrentValue() &&
           (focus.GetCurrentValue()==CrFocusIndicator_Focused_AF_S || focus.GetCurrentValue()==CrFocusIndicator_Focused_AF_C))return true;
    }while(Clock::now()<deadline);
    *message=@"未在3秒内收到合焦确认，未发出快门。请检查拍摄对象和对焦模式后重试。";
    return false;
}

bool setDirectory(NSString *directory,NSString **message,bool remember=true) {
    if (!directory.length) { *message=@"请选择照片保存文件夹。"; return false; }
    directory=directory.stringByExpandingTildeInPath.stringByStandardizingPath;
    if (!directory.isAbsolutePath) { *message=@"照片保存路径必须为绝对路径。"; return false; }
    NSError *error=nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:&error]) {
        *message=[@"无法创建保存文件夹：" stringByAppendingString:error.localizedDescription ?: @""]; return false;
    }
    std::string probe([[directory stringByAppendingPathComponent:@".lr1-write-XXXXXX"] fileSystemRepresentation]);
    std::vector<char> buffer(probe.begin(),probe.end()); buffer.push_back(0);
    int fd=mkstemp(buffer.data());
    if (fd<0) { *message=@"照片保存文件夹不可写。"; return false; }
    bool writable=write(fd,"LR1",3)==3; close(fd); unlink(buffer.data());
    if (!writable) { *message=@"照片保存文件夹写入失败。"; return false; }
    auto &s=state();
    bool connected; {std::lock_guard<std::mutex> lock(s.mutex);connected=s.connected;}
    if (connected) {
        char prefix[]="";
        CrError sdkError=SetSaveInfo(s.handle,const_cast<char*>(directory.fileSystemRepresentation),prefix,-1);
        if (sdkError) { *message=[@"设置照片保存目录失败：" stringByAppendingString:errorText(sdkError)]; return false; }
    }
    if(remember){std::lock_guard<std::mutex> lock(s.mutex);s.saveDirectory=[directory copy];}
    return true;
}

bool configurePC(NSString **message) {
    auto &s=state(); NSString *directory;
    CrDeviceProperty exposure;
    if(readProperty(CrDeviceProperty_ExposureProgramMode,exposure) && exposure.IsGetEnableCurrentValue()) {
        if(NSString *mode=nonStillExposureLabel(exposure.GetCurrentValue())) {
            *message=[NSString stringWithFormat:@"相机处于%@模式，请将机身 Still/Movie/S&Q 开关拨到照片（Still），再拍照。",mode];
            return false;
        }
    }
    {std::lock_guard<std::mutex> lock(s.mutex);directory=s.saveDirectory;}
    if (!setDirectory(directory,message)) return false;
    if (!setValue(CrDeviceProperty_StillImageStoreDestination,CrStillImageStoreDestination_HostPC,message,true)) return false;
    if (!setValue(CrDeviceProperty_ReleaseWithoutCard,CrReleaseWithoutCard_Enable,message,true)) return false;
    if (!setValue(CrDeviceProperty_DriveMode,CrDrive_Single,message,true)) return false;
    // On ILX-LR1, Save Image Size and RAW+J/RAW+H Save Image apply only
    // to Dest.+Camera. Destination Only transfers the selected photo format;
    // those inactive properties must not prevent no-card PC capture.
    CrDeviceProperty fileType;
    if (!readProperty(CrDeviceProperty_FileType,fileType) || !fileType.IsGetEnableCurrentValue()) { *message=@"无法确认照片格式。"; return false; }
    return true;
}

NSString *burstModeLabel(uint64_t mode) {
    switch(mode) {
    case CrDrive_Continuous_Hi_Plus:return @"Hi+ 高速增强";
    case CrDrive_Continuous_Hi:return @"Hi 高速";
    case CrDrive_Continuous_Mid:return @"Mid 中速";
    case CrDrive_Continuous_Lo:return @"Lo 低速";
    default:return nil;
    }
}

double exposureSeconds(const CrDeviceProperty &shutter) {
    if(!shutter.IsGetEnableCurrentValue())return -1;
    uint64_t v=shutter.GetCurrentValue();
    if(v==CrShutterSpeed_Bulb||v==CrShutterSpeed_Nothing)return -1;
    unsigned numerator=(v>>16)&0xFFFF,denominator=v&0xFFFF;
    return numerator&&denominator?double(numerator)/denominator:-1;
}

bool stopBurst(NSString **message) {
    auto &s=state();bool needRelease,held;
    {std::lock_guard<std::mutex> lock(s.mutex);
        needRelease=s.burstActive||s.burstReleasePending;held=s.burstS1Held;
        if(!needRelease){*message=s.burstDraining?@"连拍已停止，正在收齐照片。":@"当前没有进行中的连拍。";return true;}
        s.burstStopRequested=true;
    }
    // Do this before any lifecycle/epoch change. Even a failed Down must be
    // paired with Up; unsuccessful stop attempts remain pending and retry.
    CrError error=SendCommand(s.handle,CrCommandId_Release,CrCommandParam_Up);
    if(error) {
        std::this_thread::sleep_for(std::chrono::milliseconds(35));
        error=SendCommand(s.handle,CrCommandId_Release,CrCommandParam_Up);
    }
    NSString *unlockMessage=@"";
    bool unlocked=!held||setValue(CrDeviceProperty_S1,CrLockIndicator_Unlocked,&unlockMessage,true);
    CrDeviceProperty s2;
    bool released=!error&&readProperty(CrDeviceProperty_S2,s2)&&s2.IsGetEnableCurrentValue()&&s2.GetCurrentValue()==CrLockIndicator_Unlocked;
    {std::lock_guard<std::mutex> lock(s.mutex);
        if(!error && s.burstActive) {
            s.burstActive=false;s.burstDraining=true;s.burstStopped=Clock::now();
            s.burstElapsed=std::chrono::duration<double>(s.burstStopped-s.burstStarted).count();
            s.burstEmptyPolls=0;
        }
        if(unlocked)s.burstS1Held=false;
        s.burstReleasePending=error||!unlocked||!released;
        if(s.burstReleasePending) {
            *message=error?[@"尚未确认连拍停止：" stringByAppendingString:errorText(error)]:
                (!unlocked?[@"尚未释放半按对焦：" stringByAppendingString:unlockMessage]:@"正在等待相机确认快门已释放。");
            s.burstStatus=*message;
        } else {
            *message=@"连拍已停止，正在收齐照片。";
            s.burstStatus=s.burstError.length?s.burstError:*message;
        }
        s.changed.notify_all();
    }
    if(error||!unlocked||!released){logLifecycleError(*message);return false;}
    return true;
}

bool burstGroupsCompleteLocked() {
    auto &s=state();
    return s.burstDownloaded>0 && s.burstDownloaded==s.burstGroups.size() &&
           s.burstDownloaded>=s.burstCaptured;
}

void serviceBurst() {
    auto &s=state();bool stop=false,poll=false;uint64_t id=0,serial=0;
    {std::lock_guard<std::mutex> lock(s.mutex);
        if(!s.connected||!burstBusyLocked())return;
        stop=s.burstReleasePending||(s.burstActive&&(s.burstStopRequested||Clock::now()>=s.burstDeadline));
    }
    if(stop){NSString *message=@"";stopBurst(&message);}
    {std::lock_guard<std::mutex> lock(s.mutex);auto now=Clock::now();
        if(!s.burstDraining||s.burstActive||s.burstReleasePending)return;
        if(!s.burstTimedOut && now-s.burstStopped>std::chrono::minutes(5)) {
            s.burstTimedOut=true;s.burstStatus=@"连拍已停止，但未能确认全部照片回传；请检查文件和日志。";
            logLocked(s.burstStatus,true);
        }
        if(now-s.burstLastPoll>=std::chrono::milliseconds(300)) {
            s.burstLastPoll=now;poll=true;id=s.burstID;serial=s.burstEventSerial;
        }
    }
    if(!poll)return;
    CrDeviceProperty queue,shutter,exposure;
    bool queueKnown=readProperty(CrDeviceProperty_SnapshotInfo,queue)&&queue.IsGetEnableCurrentValue();
    bool empty=queueKnown&&queue.GetCurrentValue()==0;
    bool shutterKnown=readProperty(CrDeviceProperty_S2,shutter)&&shutter.IsGetEnableCurrentValue();
    bool released=shutterKnown&&shutter.GetCurrentValue()==CrLockIndicator_Unlocked;
    double seconds=readProperty(CrDeviceProperty_ShutterSpeed,exposure)?exposureSeconds(exposure):-1;
    bool complete=false;
    {std::lock_guard<std::mutex> lock(s.mutex);auto now=Clock::now();
        if(id!=s.burstID||s.burstActive||!s.burstDraining||s.burstReleasePending)return;
        // SnapshotInfo is a flag/bitfield, not a count. A readback of released
        // S2, fresh shutter duration and repeated empty snapshots are needed.
        if(seconds>0)s.burstShutterSeconds=std::max(s.burstShutterSeconds,seconds);
        double settleSeconds=std::max(1.5,s.burstShutterSeconds+0.75);
        bool settled=seconds>0 && std::chrono::duration<double>(now-s.burstStopped).count()>=settleSeconds &&
                     std::chrono::duration<double>(now-s.burstLastEvent).count()>=settleSeconds;
        if(empty&&released&&settled&&serial==s.burstEventSerial)++s.burstEmptyPolls;else s.burstEmptyPolls=0;
        complete=s.burstEmptyPolls>=2&&burstGroupsCompleteLocked()&&!s.burstError.length;
        if(!complete&&!s.burstTimedOut&&!s.burstError.length)
            s.burstStatus=queueKnown?@"连拍已停止，正在确认全部照片回传。":@"连拍已停止，暂时无法读取待传照片状态。";
    }
    if(!complete)return;
    NSString *restoreMessage=@"";bool restored=setValue(CrDeviceProperty_DriveMode,CrDrive_Single,&restoreMessage,true);
    NSString *directory;{std::lock_guard<std::mutex> lock(s.mutex);directory=s.saveDirectory;}
    NSString *directoryMessage=@"";bool directoryRestored=setDirectory(directory,&directoryMessage,false);
    if(!directoryRestored){restored=false;restoreMessage=directoryMessage;}
    {std::lock_guard<std::mutex> lock(s.mutex);
        if(id!=s.burstID||serial!=s.burstEventSerial||!s.burstDraining)return;
        s.burstDraining=false;s.pendingPhoto=false;s.pendingKinds.clear();
        s.burstStatus=restored?[NSString stringWithFormat:@"连拍完成：%llu 张照片，%llu 个文件。",(unsigned long long)s.burstDownloaded,(unsigned long long)s.burstFiles]:
            [@"照片已收齐，但恢复单张模式失败：" stringByAppendingString:restoreMessage];
        if(!restored)s.configurationError=restoreMessage;
        logLocked(s.burstStatus,!restored);s.changed.notify_all();
    }
}

void monitorBurst(uint64_t epoch,uint64_t id) {
    @autoreleasepool {
        auto &s=state();
        while(true) {
            {std::unique_lock<std::mutex> lock(s.mutex);
                if(epoch!=s.epoch||id!=s.burstID||!burstBusyLocked())return;
                if(s.burstActive&&!s.burstStopRequested&&!s.burstReleasePending)
                    s.changed.wait_until(lock,s.burstDeadline,[&]{return epoch!=s.epoch||id!=s.burstID||s.burstStopRequested||!s.burstActive;});
                else s.changed.wait_for(lock,std::chrono::milliseconds(150));
                if(epoch!=s.epoch||id!=s.burstID||!burstBusyLocked())return;
            }
            std::lock_guard<std::mutex> serial(s.api);
            {std::lock_guard<std::mutex> lock(s.mutex);if(epoch!=s.epoch||id!=s.burstID)return;}
            serviceBurst();
        }
    }
}

void refreshProperties() {
    auto &s=state();
    {std::lock_guard<std::mutex> lock(s.mutex);if (!s.connected || !s.handle) return;}
    CrDeviceProperty *list=nullptr; CrInt32 count=0;
    CrError error=GetDeviceProperties(s.handle,&list,&count);
    if (error || !list) {
        if(list) ReleaseDeviceProperties(s.handle,list);
        std::lock_guard<std::mutex> lock(s.mutex);s.recordingKnown=false; return;
    }
    NSMutableArray *rows=[NSMutableArray array],*burstModes=[NSMutableArray array]; bool known=false,recording=false;
    for (const auto &name:propertyNames) {
        for (int i=0;i<count;++i) {
            const auto &p=list[i];
            if (p.GetCode()!=name.code || p.GetPropertyEnableFlag()==CrEnableValue_NotSupported || p.GetValueType()==CrDataType_STR) continue;
            auto possible=values(p); NSMutableArray *options=[NSMutableArray array];
            if(name.code==CrDeviceProperty_DriveMode&&p.IsSetEnableCurrentValue())
                for(uint64_t value:possible)if(NSString *title=burstModeLabel(value))
                    [burstModes addObject:@{@"value":decimal(value),@"label":title}];
            for(uint64_t value:possible) {
                if(name.code==CrDeviceProperty_ShutterSpeed && value==CrShutterSpeed_Bulb) continue;
                [options addObject:@{@"value":valueString(value,p.GetValueType()),@"label":label(p.GetCode(),value,p.GetValueType())}];
            }
            bool writable=p.IsSetEnableCurrentValue() && options.count>0;
            // These settings are managed by the no-card download path.
            if (name.code==CrDeviceProperty_StillImageStoreDestination || name.code==CrDeviceProperty_ReleaseWithoutCard ||
                name.code==CrDeviceProperty_Still_Image_Trans_Size || name.code==CrDeviceProperty_RAW_J_PC_Save_Image ||
                name.code==CrDeviceProperty_DriveMode) writable=false;
            [rows addObject:@{@"code":@(name.code),@"name":text(name.name),@"value":valueString(p.GetCurrentValue(),p.GetValueType()),
                              @"label":p.IsGetEnableCurrentValue()?label(name.code,p.GetCurrentValue(),p.GetValueType()):@"当前不可读取",
                              @"writable":@(writable),@"options":options}];
            break;
        }
    }
    for (int i=0;i<count;++i) if (list[i].GetCode()==CrDeviceProperty_RecordingState && list[i].IsGetEnableCurrentValue()) {
        uint64_t v=list[i].GetCurrentValue();
        known=v<=CrMovie_Recording_State_IntervalRec_Waiting_Record;
        recording=v==CrMovie_Recording_State_Recording || v==CrMovie_Recording_State_IntervalRec_Waiting_Record;
    }
    ReleaseDeviceProperties(s.handle,list);
    std::lock_guard<std::mutex> lock(s.mutex);
    if (s.connected) {s.properties=[rows copy];s.recordingKnown=known;s.recording=recording;if(!burstBusyLocked())s.burstModes=[burstModes copy];}
}

bool disconnectDevice(NSString **message) {
    auto &s=state(); CrDeviceHandle handle=s.handle; Callback *callback=s.callback;
    bool stop;{std::lock_guard<std::mutex> lock(s.mutex);stop=s.burstActive||s.burstReleasePending;}
    if(stop&&!stopBurst(message))return false;
    {std::lock_guard<std::mutex> lock(s.mutex);++s.epoch;s.connected=s.connecting=s.configured=s.recordingKnown=s.recording=false;
     if(s.burstDraining){s.burstStatus=@"连接已断开，未确认全部连拍照片回传。";logLocked(s.burstStatus,true);}
     s.burstActive=s.burstDraining=s.burstReleasePending=s.burstS1Held=false;++s.burstID;s.burstModes=@[];s.changed.notify_all();
     resetManualFocusLocked();s.pendingPhoto=false;s.pendingKinds.clear();s.properties=@[];s.cameraName=@"";s.configurationError=@"";}
    if (!handle) return true;
    // Official connect.cpp releases the handle after initial OnError without
    // calling Disconnect when OnConnected never occurred. Keep this distinct
    // from a local wait timeout or an error on a previously connected session.
    bool failedInitial=callback&&callback->initialConnectFailed.load()&&!callback->everConnected.load();
    if(!failedInitial) {
    bool firstRequest=!s.disconnectPending;
    if(firstRequest && !(callback && callback->disconnected)) {
        CrError disconnectError=Disconnect(handle);
        if(disconnectError) {*message=[@"相机断开请求失败：" stringByAppendingString:errorText(disconnectError)];return false;}
        s.disconnectPending=true;
    }
    if (callback && !callback->disconnected && firstRequest) {
        std::unique_lock<std::mutex> lock(s.mutex);
        s.changed.wait_for(lock,std::chrono::seconds(3),[&]{return callback->disconnected.load();});
    }
    // SDK contract: neither ReleaseDevice nor Release may run before the
    // OnDisconnected notification. Keep the handle alive on timeout.
    if(!callback || !callback->disconnected) {*message=@"正在等待相机断开确认，连接资源暂时保留。";return false;}
    }
    CrError error=ReleaseDevice(handle);
    if (error) { *message=[@"释放相机连接失败：" stringByAppendingString:errorText(error)];return false; }
    s.handle=0;s.callback=nullptr;s.disconnectPending=false;
    return true;
}

void service() {
    auto &s=state(); bool timeout=false,stale=false,configure=false;
    serviceBurst();
    serviceManualFocus();
    {std::lock_guard<std::mutex> lock(s.mutex);
        timeout=s.connecting && Clock::now()-s.connectStarted>std::chrono::seconds(15);
        stale=s.handle && !s.connected && !s.connecting;
        configure=s.connected && !s.configured && !burstBusyLocked();
        if (s.pendingPhoto && !burstBusyLocked() && Clock::now()-s.photoStarted>std::chrono::seconds(90)) {
            s.pendingPhoto=false;
            logLocked(s.captureConfirmed?@"已收到拍摄事件，但照片下载超时，请检查日志和本地文件。":@"未收到拍摄或文件确认；请检查自动对焦是否合焦及相机提示后重试。",true);
        }
    }
    if (timeout || stale) {
        NSString *message=@"";
        if(timeout) logLifecycleError(@"连接超时，未把相机标记为已连接。");
        if(!disconnectDevice(&message)) logLifecycleError(message);
        return;
    }
    if(configure) {
        NSString *message=@""; bool configured=configurePC(&message);
        std::lock_guard<std::mutex> lock(s.mutex);
        // Attempt once per connection; shoot rechecks the entire path.
        if(!s.connected)return;
        s.configured=true;s.configurationError=configured?@"":message;
        logLocked(configured?@"已确认无卡单张拍摄，照片按相机格式保存到 Mac。":message,!configured);
    }
}

NSString *cameraID(const ICrCameraObjectInfo *info) {
    if ([text(info->GetConnectionTypeName()) isEqual:@"IP"] && info->GetMACAddressChar()) return text(info->GetMACAddressChar());
    const uint8_t *bytes=info->GetId();size_t length=std::min<uint32_t>(info->GetIdSize(),4096);
    if (!bytes || !length) return @"";
    while(length && bytes[length-1]==0) --length;
    bool printable=true;for(size_t i=0;i<length;++i) if(bytes[i]<0x20 || bytes[i]==0x7F) printable=false;
    NSString *decoded=printable?[[NSString alloc] initWithBytes:bytes length:length encoding:NSUTF8StringEncoding]:nil;
    if(decoded) return decoded;
    NSMutableString *hex=[NSMutableString string];
    for(size_t i=0;i<length;++i) [hex appendFormat:@"%02X",bytes[i]];
    return hex;
}

std::string normalizedFingerprint(std::string fingerprint) {
    fingerprint.erase(std::remove_if(fingerprint.begin(),fingerprint.end(),[](unsigned char c){return std::isspace(c)||c==0;}),fingerprint.end());
    // GetFingerprint returns Base64 text, not a hexadecimal digest.
    return fingerprint;
}

bool action(NSDictionary *request,NSString **message) {
    auto &s=state();NSString *name=[request[@"action"] isKindOfClass:NSString.class]?request[@"action"]:@"";
    service();
    {std::lock_guard<std::mutex> lock(s.mutex);
        if(focusBusyLocked()&&![name isEqual:@"status"]&&![name isEqual:@"focus_cancel"]) {
            *message=@"镜头正在调整，请等待完成或停止对焦后再操作。";return false;
        }
        if(burstBusyLocked()&&![name isEqual:@"status"]&&![name isEqual:@"burst_stop"]&&
           ![name isEqual:@"disconnect"]&&![name isEqual:@"shutdown"]) {
            *message=@"连拍或照片回传尚未结束，请先停止并等待照片收齐。";return false;
        }
    }
    if([name isEqual:@"burst_stop"])return stopBurst(message);
    if ([name isEqual:@"initialize"]) {
        {std::lock_guard<std::mutex> lock(s.mutex);if(s.pendingPhoto) {*message=@"正在下载照片，请完成后再初始化。";return false;}}
        NSString *directory=[request[@"saveDirectory"] isKindOfClass:NSString.class]?request[@"saveDirectory"]:[NSHomeDirectory() stringByAppendingPathComponent:@"Pictures/LR1Control"];
        if(!setDirectory(directory,message)) return false;
        if(!s.initialized) {
            if(!Init()) {*message=@"相机 SDK 初始化失败，请检查应用中的 SDK 文件。";return false;}
            uint32_t version=GetSDKVersion();std::lock_guard<std::mutex> lock(s.mutex);s.initialized=true;
            logLocked([NSString stringWithFormat:@"相机 SDK 已初始化（0x%08X）。",version]);
        }
        *message=@"已准备好，请扫描相机。";return true;
    }
    if ([name isEqual:@"status"]) {refreshProperties();refreshManualFocus();std::lock_guard<std::mutex> lock(s.mutex);*message=s.configurationError.length?s.configurationError:@"";return !s.configurationError.length;}
    if ([name isEqual:@"shutdown"]) {
        bool ok=disconnectDevice(message);
        if(!ok)return false;
        if(s.enumeration) {s.enumeration->Release();s.enumeration=nullptr;}
        if(s.initialized) {
            bool released=Release();
            if(!released) {ok=false;*message=@"相机 SDK 释放失败。";}
            else {std::lock_guard<std::mutex> lock(s.mutex);s.initialized=false;s.handle=0;s.callback=nullptr;}
        }
        {std::lock_guard<std::mutex> lock(s.mutex);s.cameras=@[];}
        if(ok) *message=@"相机 SDK 已关闭。";
        return ok;
    }
    if ([name isEqual:@"disconnect"]) {bool ok=disconnectDevice(message);if(ok)*message=@"已断开相机。";return ok;}
    if ([name isEqual:@"set_save_directory"]) {
        {std::lock_guard<std::mutex> lock(s.mutex);if(s.pendingPhoto) {*message=@"正在下载照片，请完成后再更改文件夹。";return false;}}
        NSString *path=[request[@"path"] isKindOfClass:NSString.class]?request[@"path"]:@"";
        bool ok=setDirectory(path,message);if(ok)*message=@"已更新照片保存文件夹。";return ok;
    }
    if(!s.initialized) {*message=@"请先初始化相机 SDK。";return false;}
    if([name isEqual:@"scan"]) {
        {std::lock_guard<std::mutex> lock(s.mutex);if(s.handle || s.connecting) {*message=@"请先断开相机，再重新扫描。";return false;}}
        if(s.enumeration) {s.enumeration->Release();s.enumeration=nullptr;}
        CrError error=EnumCameraObjects(&s.enumeration,3);
        NSMutableArray *cameras=[NSMutableArray array];
        if(!error && s.enumeration) for(uint32_t i=0;i<s.enumeration->GetCount();++i) {
            auto info=s.enumeration->GetCameraObjectInfo(i);if(!info)continue;
            NSString *model=text(info->GetModel());if(!model.length)model=text(info->GetName());
            [cameras addObject:@{@"index":@(i),@"name":model,@"connection":text(info->GetConnectionTypeName()),@"id":cameraID(info)}];
        }
        {std::lock_guard<std::mutex> lock(s.mutex);s.cameras=[cameras copy];}
        if(error) {*message=[@"扫描失败：" stringByAppendingString:errorText(error)];return false;}
        *message=cameras.count?[NSString stringWithFormat:@"找到 %lu 台相机。",(unsigned long)cameras.count]:@"未找到相机，请检查 USB 连接与电脑遥控设置。";
        return true;
    }
    if([name isEqual:@"connect"]) {
        {std::lock_guard<std::mutex> lock(s.mutex);if(s.handle || s.connecting) {*message=@"已有连接，请先断开。";return false;}}
        NSNumber *index=[request[@"index"] isKindOfClass:NSNumber.class]?request[@"index"]:nil;
        if(!index || index.longLongValue<0 || !s.enumeration || index.unsignedLongLongValue>=s.enumeration->GetCount()) {*message=@"请选择扫描列表中的相机。";return false;}
        auto info=const_cast<ICrCameraObjectInfo*>(s.enumeration->GetCameraObjectInfo(index.unsignedIntValue));
        // Explicit MovieRecord Down/Up semantics and no-card setup target LR1.
        if (![text(info->GetModel()).uppercaseString containsString:@"ILX-LR1"]) {*message=@"此工具仅连接 ILX-LR1。";return false;}
        std::string user([[request[@"user"] isKindOfClass:NSString.class]?request[@"user"]:@"" UTF8String]);
        std::string password([[request[@"password"] isKindOfClass:NSString.class]?request[@"password"]:@"" UTF8String]);
        char fingerprint[512]={0};CrInt32u fingerprintSize=0;
        if(info->GetSSHsupport()==CrSSHsupport_ON) {
            if(user.empty() || password.empty()) {*message=@"网络连接需要相机的用户名和密码。";return false;}
            NSString *expected=[request[@"fingerprint"] isKindOfClass:NSString.class]?request[@"fingerprint"]:@"";
            if(!expected.length) {*message=@"请先填写并核对相机上显示的连接指纹。";return false;}
            CrError error=GetFingerprint(info,fingerprint,&fingerprintSize);
            if(error || !fingerprintSize || fingerprintSize>sizeof(fingerprint)) {*message=@"无法读取相机连接指纹。";return false;}
            if(normalizedFingerprint(std::string(fingerprint,fingerprintSize))!=normalizedFingerprint(expected.UTF8String)) {
                *message=@"相机指纹与填写的指纹不一致，未发起连接。";return false;
            }
        }
        uint64_t epoch;
        {std::lock_guard<std::mutex> lock(s.mutex);epoch=++s.epoch;s.connecting=true;s.connected=false;s.configured=false;
         s.cameraName=text(info->GetModel());s.configurationError=@"";s.connectStarted=Clock::now();s.disconnectPending=false;}
        auto callback=std::make_unique<Callback>(epoch);s.callback=callback.get();s.callbacks.push_back(std::move(callback));
        CrDeviceHandle handle=0;
        CrError error=Connect(info,s.callback,&handle,CrSdkControlMode_Remote,CrReconnecting_OFF,
                              user.c_str(),password.c_str(),fingerprint,fingerprintSize);
        std::fill(password.begin(),password.end(),'\0');s.handle=handle;
        if(error) {
            NSString *ignored=@"";disconnectDevice(&ignored);
            *message=[@"连接请求失败：" stringByAppendingString:errorText(error)];return false;
        }
        *message=@"已发出连接请求，等待相机确认。";return true;
    }
    {std::lock_guard<std::mutex> lock(s.mutex);if(!s.connected || !s.handle) {*message=@"相机尚未连接。";return false;}}
    if([name isEqual:@"focus_cancel"])return cancelManualFocus(message);
    if([name isEqual:@"focus_step"]||[name isEqual:@"focus_position"]) {
        {std::lock_guard<std::mutex> lock(s.mutex);if(s.pendingPhoto){*message=@"照片尚在处理，请完成后再调整对焦。";return false;}}
        refreshManualFocus();
        {std::lock_guard<std::mutex> lock(s.mutex);
         if(!s.focusIsMF){*message=@"请先将对焦模式设为 MF 手动。";return false;}
         if(focusBusyLocked()){*message=@"镜头正在调整，请稍后重试。";return false;}}
        int64_t value=0;
        if([name isEqual:@"focus_step"]) {
            int64_t lo=0,hi=0,increment=0;
            if(!integerArgument(request[@"step"],value)||value==0||value<-7||value>7){*message=@"近远微调档位须为 -7 至 -1 或 1 至 7 的整数。";return false;}
            if(!nearFarRange(lo,hi,increment)||!inRange(value,lo,hi,increment)){*message=@"当前镜头或相机状态不支持此近远微调档位。";return false;}
            // The SDK API carries signed control values in its 64-bit ABI.
            // Match Sony's int64_t sample; truncating -1 to UInt16 gives 65535
            // and is rejected as outside the NearFar range.
            CrError error=ExecuteControlCodeValue(s.handle,CrControlCode_NearFar,static_cast<CrInt64u>(value));
            if(error){*message=[@"近远微调请求失败：" stringByAppendingString:errorText(error)];return false;}
            {std::lock_guard<std::mutex> lock(s.mutex);s.focusStepUntil=Clock::now()+std::chrono::milliseconds(250);
             s.focusStatus=[NSString stringWithFormat:@"已提交向%@微调（%lld 档），请查看取景画面。",value<0?@"近":@"远",(long long)std::abs(value)];*message=s.focusStatus;}
            return true;
        }
        if(!integerArgument(request[@"value"],value)){*message=@"绝对对焦位置须为整数。";return false;}
        CrDeviceProperty property;int64_t lo=0,hi=0,increment=0;
        if(!readProperty(CrDeviceProperty_FocusPositionSetting,property)||!property.IsSetEnableCurrentValue()||
           property.GetValueType()!=CrDataType_UInt16Range||!numericRange(property.GetValueType(),property.GetValues(),property.GetValueSize(),lo,hi,increment)||
           lo<0||hi>65535||!inRange(value,lo,hi,increment)){*message=@"绝对对焦位置不在镜头当前可用范围中，或当前不可设置。";return false;}
        uint64_t epoch,id;
        {std::lock_guard<std::mutex> lock(s.mutex);
         if(!s.focusPositionEnabled){*message=@"当前无法读取镜头实际位置，未移动镜头。";return false;}
         if(s.focusPosition&&s.focusPosition.longLongValue==value){*message=@"镜头实际位置已是此值。";return true;}
         epoch=s.epoch;id=++s.focusID;s.focusPending=true;s.focusResult=0;s.focusTimedOut=s.focusCancelRequested=s.focusCancelButtonHeld=false;
         s.focusStarted=Clock::now();s.focusLastPoll={};s.focusStatus=@"正在调整绝对对焦位置，等待相机结果。";}
        // Start the monitor before submitting motion, so a thread-creation
        // failure cannot leave an unmonitored absolute move.
        try {std::thread(monitorManualFocus,epoch,id).detach();}
        catch(...) {std::lock_guard<std::mutex> lock(s.mutex);s.focusPending=false;++s.focusID;*message=@"无法启动对焦状态监测，未移动镜头。";return false;}
        property.SetCurrentValue((uint64_t)value);CrError error=SetDeviceProperty(s.handle,&property);
        if(error){std::lock_guard<std::mutex> lock(s.mutex);s.focusPending=false;++s.focusID;s.changed.notify_all();*message=[@"绝对对焦请求失败：" stringByAppendingString:errorText(error)];s.focusStatus=*message;return false;}
        *message=@"已提交绝对对焦位置，等待相机确认实际位置。";return true;
    }
    if([name isEqual:@"set_property"]) {
        NSNumber *code=[request[@"code"] isKindOfClass:NSNumber.class]?request[@"code"]:nil;
        NSString *string=[request[@"value"] isKindOfClass:NSString.class]?request[@"value"]:nil;
        if(!code || !string.length || !exposedProperty(code.unsignedIntValue)) {*message=@"参数请求无效。";return false;}
        uint32_t c=code.unsignedIntValue;
        if(c==CrDeviceProperty_StillImageStoreDestination || c==CrDeviceProperty_ReleaseWithoutCard ||
           c==CrDeviceProperty_Still_Image_Trans_Size || c==CrDeviceProperty_RAW_J_PC_Save_Image || c==CrDeviceProperty_DriveMode) {*message=@"电脑直传与单张拍摄参数由软件自动维护。";return false;}
        std::string raw=string.UTF8String;size_t end=0;uint64_t value;
        try {value=raw[0]=='-'?(uint64_t)std::stoll(raw,&end,10):std::stoull(raw,&end,10);}catch(...) {*message=@"参数值必须为十进制整数。";return false;}
        if(end!=raw.size()) {*message=@"参数值必须为十进制整数。";return false;}
        if(c==CrDeviceProperty_ShutterSpeed && value==CrShutterSpeed_Bulb) {*message=@"当前工具不提供 B 门长曝光，请选择固定快门时间。";return false;}
        if(!setValue(c,value,message,true))return false;
        // Sony requires 500 ms after changing ExposureProgramMode before
        // setting related shooting properties. Keep the API queue serialized.
        if(c==CrDeviceProperty_ExposureProgramMode)std::this_thread::sleep_for(std::chrono::milliseconds(500));
        refreshProperties();if(c==CrDeviceProperty_FocusMode)refreshManualFocus();*message=[propertyName(c) stringByAppendingString:@"已由相机确认。"];return true;
    }
    if([name isEqual:@"autofocus"]) {
        HalfPress halfPress;
        if(!lockAndWaitForFocus(halfPress,message))return false;
        NSString *releaseMessage=@"";bool released=halfPress.release(&releaseMessage);
        if(!released) {*message=releaseMessage;return false;}
        *message=@"相机已报告合焦。";return true;
    }
    if([name isEqual:@"burst_start"]) {
        {std::lock_guard<std::mutex> lock(s.mutex);if(s.pendingPhoto){*message=@"上一张照片仍在处理，请完成后再开始连拍。";return false;}}
        NSString *raw=[request[@"mode"] isKindOfClass:NSString.class]?request[@"mode"]:@"";
        uint64_t mode=0;size_t end=0;
        try {mode=std::stoull(raw.UTF8String,&end,10);}catch(...){*message=@"请选择相机支持的连拍档位。";return false;}
        if(end!=strlen(raw.UTF8String)||!burstModeLabel(mode)){*message=@"请选择 Hi+、Hi、Mid 或 Lo 连拍档位。";return false;}
        double duration=request[@"duration"]?[request[@"duration"] doubleValue]:1.0;
        if(!std::isfinite(duration)||duration<0.5||duration>10){*message=@"连拍时长须为0.5至10秒。";return false;}
        if(!configurePC(message))return false;
        CrDeviceProperty shutter,queue,file,focus;
        double seconds=readProperty(CrDeviceProperty_ShutterSpeed,shutter)?exposureSeconds(shutter):-1;
        if(seconds<=0||seconds>1){*message=@"开始连拍前需能读取不长于1秒的快门；B门不可用于定时连拍。单张拍摄不受此限制。";return false;}
        if(!readProperty(CrDeviceProperty_SnapshotInfo,queue)||!queue.IsGetEnableCurrentValue()||queue.GetCurrentValue()!=0) {
            *message=@"相机尚有待传照片，或暂时不能确认传输队列为空；请稍后开始连拍。";return false;
        }
        if(!readProperty(CrDeviceProperty_FileType,file)||!file.IsGetEnableCurrentValue()){*message=@"无法确认照片格式，未开始连拍。";return false;}
        std::set<std::string> kinds;
        switch(file.GetCurrentValue()) {
        case CrFileType_Raw:kinds={"raw"};break;case CrFileType_Jpeg:kinds={"jpeg"};break;
        case CrFileType_RawJpeg:kinds={"raw","jpeg"};break;case CrFileType_RawHeif:kinds={"raw","heif"};break;
        case CrFileType_Heif:kinds={"heif"};break;default:*message=@"当前照片格式不可识别，未开始连拍。";return false;
        }
        if(!readProperty(CrDeviceProperty_FocusMode,focus)||!focus.IsGetEnableCurrentValue()){*message=@"无法确认对焦模式，未开始连拍。";return false;}
        bool needsAF=false;
        switch(focus.GetCurrentValue()) {
        case CrFocus_MF:case CrFocus_PF:break;
        case CrFocus_AF_S:case CrFocus_AF_C:case CrFocus_AF_A:case CrFocus_AF_D:case CrFocus_DMF:needsAF=true;break;
        default:*message=@"当前对焦模式不可识别，未开始连拍。";return false;
        }
        NSString *base;{std::lock_guard<std::mutex> lock(s.mutex);base=s.saveDirectory;}
        NSDateFormatter *formatter=[NSDateFormatter new];formatter.dateFormat=@"yyyyMMdd_HHmmss";
        NSString *subfolder=[NSString stringWithFormat:@"连拍_%@_%@",[formatter stringFromDate:[NSDate date]],[[NSUUID UUID].UUIDString substringToIndex:8]];
        NSString *directory=[base stringByAppendingPathComponent:subfolder];
        if(!setDirectory(directory,message,false))return false;
        if(!setValue(CrDeviceProperty_DriveMode,mode,message,true))return false;
        HalfPress halfPress;
        if(needsAF&&!lockAndWaitForFocus(halfPress,message)) {
            NSString *ignored=@"";halfPress.release(&ignored);setValue(CrDeviceProperty_DriveMode,CrDrive_Single,&ignored,true);return false;
        }
        uint64_t epoch,id;
        {std::lock_guard<std::mutex> lock(s.mutex);
            epoch=s.epoch;id=++s.burstID;s.burstActive=true;s.burstDraining=false;s.burstReleasePending=false;
            s.burstS1Held=halfPress.held;halfPress.held=false;s.burstStopRequested=false;s.burstQueueComplete=false;s.burstTimedOut=false;
            s.burstCaptured=s.burstDownloaded=s.burstFiles=s.burstEventSerial=0;s.burstEmptyPolls=0;s.burstElapsed=0;
            s.burstKinds=kinds;s.burstSeenFiles.clear();s.burstGroups.clear();s.burstDirectory=directory;s.burstError=@"";
            s.burstStarted=s.burstLastEvent=Clock::now();s.burstLastPoll={};s.burstShutterSeconds=seconds;
            s.burstDeadline=s.burstStarted+std::chrono::milliseconds((int)(duration*1000));
            s.burstStatus=[NSString stringWithFormat:@"正在%@连拍，最长保持%.1f秒。",burstModeLabel(mode),duration];
            s.pendingPhoto=true;s.captureConfirmed=false;s.photoError=@"";s.pendingKinds=kinds;s.photoStarted=s.burstStarted;
        }
        CrError down=SendCommand(s.handle,CrCommandId_Release,CrCommandParam_Down);
        if(down) {
            NSString *ignored=@"";bool stopped=stopBurst(&ignored);
            {std::lock_guard<std::mutex> lock(s.mutex);s.burstError=[@"连拍快门请求失败：" stringByAppendingString:errorText(down)];
                s.burstStatus=s.burstError;*message=s.burstError;
                if(stopped&&!s.burstCaptured&&!s.burstFiles){s.burstDraining=false;s.pendingPhoto=false;}}
            if(stopped){NSString *restore=@"";setValue(CrDeviceProperty_DriveMode,CrDrive_Single,&restore,true);}
        }
        try {std::thread(monitorBurst,epoch,id).detach();}
        catch(...) {NSString *ignored=@"";stopBurst(&ignored);*message=@"无法建立连拍计时器，已请求停止。";return false;}
        if(down)return false;
        *message=@"连拍已开始；定时器会自动抬起快门，实际张数由相机决定。";return true;
    }
    if([name isEqual:@"shoot"]) {
        {std::lock_guard<std::mutex> lock(s.mutex);if(s.pendingPhoto) {*message=@"上一张照片仍在下载，请稍候。";return false;}}
        if(!configurePC(message)) {std::lock_guard<std::mutex> lock(s.mutex);s.configurationError=*message;return false;}
        CrDeviceProperty shutter;
        if(!readProperty(CrDeviceProperty_ShutterSpeed,shutter) || !shutter.IsGetEnableCurrentValue()) {*message=@"无法确认快门速度，未拍摄。";return false;}
        if(shutter.GetCurrentValue()==CrShutterSpeed_Bulb) {*message=@"当前为 B 门模式，请选择固定快门时间后拍摄。";return false;}
        CrDeviceProperty p;if(!readProperty(CrDeviceProperty_FileType,p)) {*message=@"无法读取照片格式。";return false;}
        std::set<std::string> kinds;
        switch(p.GetCurrentValue()) {
        case CrFileType_Raw:kinds={"raw"};break;case CrFileType_Jpeg:kinds={"jpeg"};break;
        case CrFileType_RawJpeg:kinds={"raw","jpeg"};break;case CrFileType_RawHeif:kinds={"raw","heif"};break;
        case CrFileType_Heif:kinds={"heif"};break;default:*message=@"当前照片格式不可识别。";return false;
        }
        CrDeviceProperty focusMode;
        if(!readProperty(CrDeviceProperty_FocusMode,focusMode) || !focusMode.IsGetEnableCurrentValue()) {*message=@"无法确认当前对焦模式，未发出快门。";return false;}
        HalfPress halfPress;bool needsAF=false;
        switch(focusMode.GetCurrentValue()) {
        case CrFocus_MF:case CrFocus_PF:break;
        case CrFocus_AF_S:case CrFocus_AF_C:case CrFocus_AF_A:case CrFocus_AF_D:case CrFocus_DMF:needsAF=true;break;
        default:*message=@"当前对焦模式不可识别，未发出快门。";return false;
        }
        if(needsAF) {
            log(@"正在半按对焦，合焦后拍摄。");
            if(!lockAndWaitForFocus(halfPress,message))return false;
            log(@"已合焦，保持半按并释放快门。");
        }
        // Do not enter the download wait while AF is still searching or failed.
        {std::lock_guard<std::mutex> lock(s.mutex);s.pendingPhoto=true;s.captureConfirmed=false;s.photoError=@"";s.pendingKinds=kinds;s.photoStarted=Clock::now();s.configurationError=@"";}
        CrError down=SendCommand(s.handle,CrCommandId_Release,CrCommandParam_Down);
        std::this_thread::sleep_for(std::chrono::milliseconds(35));
        CrError up=SendCommand(s.handle,CrCommandId_Release,CrCommandParam_Up);
        NSString *unlockMessage=@"";bool unlocked=halfPress.release(&unlockMessage);
        if(!unlocked)log([@"快门指令后释放半按对焦失败：" stringByAppendingString:unlockMessage],true);
        if(down || up) {
            if(up) SendCommand(s.handle,CrCommandId_Release,CrCommandParam_Up);
            {std::lock_guard<std::mutex> lock(s.mutex);s.pendingPhoto=false;}
            *message=[@"快门指令未完整确认：" stringByAppendingString:errorText(down?down:up)];return false;
        }
        {std::lock_guard<std::mutex> lock(s.mutex);if(s.photoError.length){*message=s.photoError;return false;}}
        *message=@"已发出快门请求，等待相机拍摄及照片文件。";return true;
    }
    if([name isEqual:@"movie_start"] || [name isEqual:@"movie_stop"]) {
        refreshProperties();bool recording,known;
        {std::lock_guard<std::mutex> lock(s.mutex);recording=s.recording;known=s.recordingKnown;}
        if(!known) {*message=@"相机未提供有效录像状态，未发送录像指令。";return false;}
        bool start=[name isEqual:@"movie_start"];
        if(start==recording) {*message=start?@"相机已在录像。":@"相机当前未录像。";return true;}
        CrError error=SendCommand(s.handle,CrCommandId_MovieRecord,start?CrCommandParam_Down:CrCommandParam_Up);
        if(error) {*message=[@"相机录像指令失败：" stringByAppendingString:errorText(error)];return false;}
        *message=start?@"已请求相机开始录像，等待相机状态确认。视频由相机保存。":@"已请求相机停止录像，等待相机状态确认。";
        return true;
    }
    *message=@"未知操作。";return false;
}

char *snapshot(bool ok,NSString *message) {
    auto &s=state();NSDictionary *result;
    {std::lock_guard<std::mutex> lock(s.mutex);
        result=@{@"ok":@(ok),@"message":message ?: @"",@"initialized":@(s.initialized),@"connected":@(s.connected),
                 @"connecting":@(s.connecting),@"cameraName":s.cameraName ?: @"",@"cameras":[s.cameras copy],
                 @"properties":[s.properties copy],@"recording":@(s.recording),@"recordingKnown":@(s.recordingKnown),
                 @"pendingPhoto":@(s.pendingPhoto),@"captureConfirmed":@(s.captureConfirmed),
                 @"burstActive":@(s.burstActive),@"burstDraining":@(s.burstDraining),
                 @"burstCaptured":@(s.burstCaptured),@"burstDownloaded":@(s.burstDownloaded),@"burstFiles":@(s.burstFiles),
                 @"burstModes":[s.burstModes copy],@"burstElapsed":@(s.burstActive?std::chrono::duration<double>(Clock::now()-s.burstStarted).count():s.burstElapsed),
                 @"burstStatus":s.burstStatus ?: @"",
                 @"burstRecoverable":@(!s.burstActive&&!s.burstReleasePending&&s.burstDraining&&(s.burstTimedOut||s.burstError.length)),
                 @"manualFocus":@{@"isMF":@(s.focusIsMF),@"stepEnabled":@(s.focusStepEnabled),@"positionEnabled":@(s.focusPositionEnabled),
                                  @"moving":@(focusBusyLocked()),@"position":s.focusPosition ?: (id)NSNull.null,
                                  @"minimum":@(s.focusMinimum),@"maximum":@(s.focusMaximum),@"increment":@(s.focusIncrement),
                                  @"steps":[s.focusSteps copy],@"status":s.focusStatus ?: @""},
                 @"saveDirectory":s.saveDirectory ?: @"",@"downloads":[s.downloads copy],@"logs":[s.logs copy]};
    }
    NSData *data=[NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    if(!data) return nullptr;
    char *copy=(char*)malloc(data.length+1);if(!copy)return nullptr;
    memcpy(copy,data.bytes,data.length);copy[data.length]=0;return copy;
}
} // namespace

extern "C" char *lr1_request(const char *json) {
    @autoreleasepool {
        std::lock_guard<std::mutex> serial(state().api);
        @try {
            try {
                if(!json)return snapshot(false,@"请求为空。");
                NSData *data=[NSData dataWithBytes:json length:strlen(json)];
                id object=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if(![object isKindOfClass:NSDictionary.class])return snapshot(false,@"请求 JSON 无效。");
                NSString *message=@"";bool ok=action((NSDictionary*)object,&message);
                NSString *name=object[@"action"];
                if(message.length && ![name isEqual:@"status"])log(message,!ok);
                return snapshot(ok,message);
            } catch(const std::exception &) {log(@"处理相机请求时发生内部错误。",true);return snapshot(false,@"相机请求未完成。");}
        } @catch(NSException *) {return snapshot(false,@"相机请求参数无效。");}
    }
}

extern "C" unsigned char *lr1_copy_live_view(int *length) {
    if(length)*length=0;if(!length)return nullptr;
    @autoreleasepool {
        std::lock_guard<std::mutex> serial(state().api);auto &s=state();
        {std::lock_guard<std::mutex> lock(s.mutex);if(!s.connected || !s.handle)return nullptr;}
        try {
            auto failure=[&](CrError e) {
                if(Clock::now()-s.lastLiveError>std::chrono::seconds(5)) {s.lastLiveError=Clock::now();log([@"实时取景暂不可用：" stringByAppendingString:errorText(e)],true);}
            };
            bool prepared;{std::lock_guard<std::mutex> lock(s.mutex);prepared=s.liveViewPrepared;}
            if(!prepared) {
                CrError settingError=SetDeviceSetting(s.handle,Setting_Key_EnableLiveView,CrDeviceSetting_Enable);
                if(settingError){failure(settingError);return nullptr;}
                std::lock_guard<std::mutex> lock(s.mutex);s.liveViewPrepared=true;
            }
            CrDeviceProperty status;
            if(!readProperty(CrDeviceProperty_LiveViewStatus,status) || !status.IsGetEnableCurrentValue() || status.GetCurrentValue()!=CrLiveView_Enable)return nullptr;
            CrImageInfo info;CrError error=GetLiveViewImageInfo(s.handle,&info);
            if(error){failure(error);return nullptr;}
            uint32_t size=info.GetBufferSize();if(size==0 || size>32*1024*1024)return nullptr;
            std::vector<uint8_t> buffer(size);CrImageDataBlock block;block.SetData(buffer.data());block.SetSize(size);
            error=GetLiveViewImage(s.handle,&block);if(error){failure(error);return nullptr;}
            uint32_t imageSize=block.GetImageSize();const uint8_t *bytes=block.GetImageData();
            if(!bytes || imageSize<4 || imageSize>size || bytes[0]!=0xFF || bytes[1]!=0xD8)return nullptr;
            auto *copy=(unsigned char*)malloc(imageSize);if(!copy)return nullptr;
            memcpy(copy,bytes,imageSize);*length=(int)imageSize;return copy;
        } catch(...) {return nullptr;}
    }
}

extern "C" void lr1_free(void *memory) { free(memory); }
