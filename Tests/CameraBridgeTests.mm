// Offline SDK-boundary tests. All bridge SDK entry points are mocked; the
// vendor library is linked only for property/control metadata constructors.
// LR1_BRIDGE_TESTING also disables persistent application logs.
#include "CrDeviceProperty.h"
#define private public
#include "CrControlCode.h"
#undef private
#define LR1_BRIDGE_TESTING 1
#include "CameraBridge.mm"
#include <cassert>
#include <iostream>
static std::mutex fakeMutex;
static std::map<uint32_t,uint64_t> fakeValues;
static std::atomic<int> downCalls{0},upCalls{0},releaseCalls{0},disconnectCalls{0};
static NSString *lastSavePath=@"";
static NSString *testDirectory=nil;
static bool manualMetadata=false;
static std::atomic<int> focusStepsSent{0},focusCancelDowns{0},focusCancelUps{0};
static uint64_t lastStepValue=0;
namespace SCRSDK {
extern "C" CrError EnumCameraObjects(ICrEnumCameraObjectInfo**,CrInt8u){std::abort();}
extern "C" CrError GetFingerprint(ICrCameraObjectInfo*,char*,CrInt32u*){std::abort();}
extern "C" CrError GetLiveViewImage(CrDeviceHandle,CrImageDataBlock*){std::abort();}
extern "C" CrError GetLiveViewImageInfo(CrDeviceHandle,CrImageInfo*){std::abort();}
extern "C" CrError SetDeviceSetting(CrDeviceHandle,CrInt32u,CrInt32u){std::abort();}
extern "C" CrInt32u GetSDKVersion(){return 0;}
extern "C" bool Init(CrInt32u){assert(false&&"Hardware initialization forbidden");return false;}
extern "C" CrError Connect(ICrCameraObjectInfo*,IDeviceCallback*,CrDeviceHandle*,CrSdkControlMode,CrReconnectingSet,const char*,const char*,const char*,CrInt32u,const CrInt16u*){assert(false&&"Hardware connection forbidden");return CrError_Generic_Unknown;}
extern "C" bool Release(){return true;}
extern "C" CrError GetSelectDeviceProperties(CrDeviceHandle,CrInt32u n,CrInt32u *codes,CrDeviceProperty **out,CrInt32 *count){
    std::lock_guard<std::mutex> lock(fakeMutex);*out=new CrDeviceProperty[n];*count=(int)n;
    for(unsigned i=0;i<n;++i){auto &p=(*out)[i];p.SetCode(codes[i]);p.SetValueType(CrDataType_UInt32);p.SetPropertyEnableFlag(CrEnableValue_True);p.SetPropertyVariableFlag(CrEnableValue_Variable);p.SetCurrentValue(fakeValues[codes[i]]);
        if(manualMetadata&&(codes[i]==CrDeviceProperty_FocusPositionSetting||codes[i]==CrDeviceProperty_FocusPositionCurrentValue)) {
            uint16_t range[]={0,65535,1};p.SetValueType(CrDataType_UInt16Range);p.SetValueSize(sizeof(range));auto *owned=new uint8_t[sizeof(range)];memcpy(owned,range,sizeof(range));p.SetValues(owned);
        }
    }
    return 0;
}
extern "C" CrError GetDeviceProperties(CrDeviceHandle,CrDeviceProperty **out,CrInt32 *count){*out=nullptr;*count=0;return 0;}
extern "C" CrError ReleaseDeviceProperties(CrDeviceHandle,CrDeviceProperty *p){delete[] p;return 0;}
extern "C" CrError SetDeviceProperty(CrDeviceHandle,CrDeviceProperty *p){std::lock_guard<std::mutex> lock(fakeMutex);fakeValues[p->GetCode()]=p->GetCurrentValue();
    if(p->GetCode()==CrDeviceProperty_FocusPositionSetting)fakeValues[CrDeviceProperty_FocusDrivingStatus]=CrFocusDrivingStatus_Driving;
    return 0;}
extern "C" CrError SendCommand(CrDeviceHandle,CrInt32u command,CrCommandParam value){
    std::lock_guard<std::mutex> lock(fakeMutex);
    if(command==CrCommandId_CancelFocusPosition){if(value==CrCommandParam_Down)++focusCancelDowns;else {++focusCancelUps;fakeValues[CrDeviceProperty_FocusDrivingStatus]=CrFocusDrivingStatus_NotDriving;}return 0;}
    assert(command==CrCommandId_Release);
    if(value==CrCommandParam_Down){++downCalls;fakeValues[CrDeviceProperty_S2]=CrLockIndicator_Locked;}
    else {++upCalls;fakeValues[CrDeviceProperty_S2]=CrLockIndicator_Unlocked;fakeValues[CrDeviceProperty_S1]=CrLockIndicator_Unlocked;}
    return 0;
}
extern "C" CrError GetSelectControlCode(CrDeviceHandle,CrControlCode code,CrControlCodeInfo **out){
    *out=nullptr;if(!manualMetadata)return CrError_Generic_Unknown;
    *out=new CrControlCodeInfo();(*out)->code=code;
    if(code==CrControlCode_NearFar){static int16_t range[]={-7,7,1};(*out)->valueType=CrDataType_Int16Range;(*out)->valuesSize=sizeof(range);(*out)->values=(uint8_t*)range;}
    else if(code==CrControlCode_CancelFocusPosition){(*out)->valueType=CrDataType_Button;}
    else return CrError_Generic_Unknown;
    return 0;
}
extern "C" CrError ReleaseControlCodes(CrDeviceHandle,CrControlCodeInfo *info){info->values=nullptr;delete info;return 0;}
extern "C" CrError ExecuteControlCodeValue(CrDeviceHandle,CrControlCode code,CrInt64u value){
    assert(code==CrControlCode_NearFar);int64_t signedStep=0;memcpy(&signedStep,&value,sizeof(value));
    if(signedStep==0||signedStep < -7||signedStep > 7)return CrError_Generic_InvalidParameter;
    ++focusStepsSent;lastStepValue=value;return 0;
}
extern "C" CrError SetSaveInfo(CrDeviceHandle,CrChar *path,CrChar*,CrInt32){lastSavePath=[NSString stringWithUTF8String:path];return 0;}
extern "C" CrError Disconnect(CrDeviceHandle){++disconnectCalls;state().callback->OnDisconnected(0);return 0;}
extern "C" CrError ReleaseDevice(CrDeviceHandle){std::lock_guard<std::mutex> lock(fakeMutex);assert(fakeValues[CrDeviceProperty_S2]==CrLockIndicator_Unlocked);++releaseCalls;return 0;}
}
static void setFake(uint32_t code,uint64_t value){std::lock_guard<std::mutex> lock(fakeMutex);fakeValues[code]=value;}
static NSDictionary *call(NSDictionary *request){
    NSData *input=[NSJSONSerialization dataWithJSONObject:request options:0 error:nil];NSString *string=[[NSString alloc]initWithData:input encoding:NSUTF8StringEncoding];
    char *raw=lr1_request(string.UTF8String);assert(raw);NSData *data=[NSData dataWithBytes:raw length:strlen(raw)];lr1_free(raw);
    return [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
}
static void setup(){
    auto &s=state();std::lock_guard<std::mutex> lock(s.mutex);++s.epoch;s.initialized=s.connected=s.configured=true;s.connecting=false;s.handle=1;s.pendingPhoto=false;
    s.burstActive=s.burstDraining=s.burstReleasePending=false;s.configurationError=@"";
    s.saveDirectory=testDirectory;
    auto callback=std::make_unique<Callback>(s.epoch);s.callback=callback.get();s.callbacks.push_back(std::move(callback));
    setFake(CrDeviceProperty_ExposureProgramMode,CrExposure_Auto);setFake(CrDeviceProperty_ShutterSpeed,(1u<<16)|160);
    setFake(CrDeviceProperty_StillImageStoreDestination,CrStillImageStoreDestination_HostPC);setFake(CrDeviceProperty_ReleaseWithoutCard,CrReleaseWithoutCard_Enable);
    setFake(CrDeviceProperty_DriveMode,CrDrive_Single);setFake(CrDeviceProperty_FileType,CrFileType_RawHeif);setFake(CrDeviceProperty_FocusMode,CrFocus_MF);
    setFake(CrDeviceProperty_SnapshotInfo,0);setFake(CrDeviceProperty_S1,CrLockIndicator_Unlocked);setFake(CrDeviceProperty_S2,CrLockIndicator_Unlocked);
}
static void downloaded(NSString *name){
    NSString *dir;Callback *callback;{std::lock_guard<std::mutex> lock(state().mutex);dir=state().burstDirectory;callback=state().callback;}
    NSString *path=[dir stringByAppendingPathComponent:name];[@"test-file" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    callback->OnCompleteDownload((char*)path.UTF8String,0xFFFFFFFF);
}
static void captured(){state().callback->OnWarning(CrNotify_Captured_Event);}
static void pause(int ms){std::this_thread::sleep_for(std::chrono::milliseconds(ms));}
int main(){@autoreleasepool{
    testDirectory=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"LR1-CameraBridgeTests-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    assert([[NSFileManager defaultManager] createDirectoryAtPath:testDirectory withIntermediateDirectories:YES attributes:nil error:nil]);
    setup();auto &s=state();
    auto start=call(@{@"action":@"burst_start",@"mode":@"65543",@"duration":@0.5});assert([start[@"ok"]boolValue]&&[start[@"burstActive"]boolValue]);
    for(NSString *key in @[@"burstActive",@"burstDraining",@"burstCaptured",@"burstDownloaded",@"burstFiles",@"burstModes",@"burstElapsed",@"burstStatus",@"burstRecoverable"])assert(start[key]);
    assert(![call(@{@"action":@"set_property",@"code":@257,@"value":@"1"})[@"ok"]boolValue]);
    setFake(CrDeviceProperty_SnapshotInfo,1);captured();captured();
    downloaded(@"DSC00001.ARW");downloaded(@"DSC00002.HIF");
    {std::lock_guard<std::mutex> lock(s.mutex);assert(s.burstFiles==2&&s.burstDownloaded==0&&s.pendingPhoto);}
    downloaded(@"DSC00002.ARW");downloaded(@"DSC00001.HIF");downloaded(@"DSC00001.ARW");
    {std::lock_guard<std::mutex> lock(s.mutex);assert(s.burstDownloaded==2&&s.burstFiles==4&&s.burstActive&&s.pendingPhoto);}
    pause(850); // No status polling: the independent timer must stop S2.
    assert(upCalls>0);{std::lock_guard<std::mutex> lock(s.mutex);assert(!s.burstActive&&s.burstDraining&&s.pendingPhoto);}
    pause(1300);{std::lock_guard<std::mutex> lock(s.mutex);assert(s.burstDraining);}
    setFake(CrDeviceProperty_SnapshotInfo,0);pause(1000);
    {std::lock_guard<std::mutex> lock(s.mutex);assert(!s.burstDraining&&!s.pendingPhoto&&s.burstDownloaded==2);assert([lastSavePath isEqual:s.saveDirectory]);}
    {std::lock_guard<std::mutex> lock(fakeMutex);assert(fakeValues[CrDeviceProperty_DriveMode]==CrDrive_Single);}
    puts("PASS: Auto mode, out-of-order RAW/HIF groups, duplicate callbacks, independent timer, queue-empty completion, Single/directory restore.");

    assert([call(@{@"action":@"burst_start",@"mode":@"65543",@"duration":@0.5})[@"ok"]boolValue]);captured();downloaded(@"DSC00003.ARW");pause(2600);
    {std::lock_guard<std::mutex> lock(s.mutex);assert(s.burstDraining&&s.pendingPhoto&&s.burstDownloaded==0);}
    s.callback->OnWarning(CrWarning_GetImage_Failed);
    auto failed=call(@{@"action":@"status"});assert([failed[@"burstRecoverable"]boolValue]&&[failed[@"pendingPhoto"]boolValue]);
    assert([call(@{@"action":@"disconnect"})[@"ok"]boolValue]);assert(releaseCalls==1);
    puts("PASS: missing HIF never completes; explicit transfer failure enables safe incomplete-disconnect recovery.");

    setup();assert([call(@{@"action":@"burst_start",@"mode":@"65543",@"duration":@10})[@"ok"]boolValue]);
    assert([call(@{@"action":@"disconnect"})[@"ok"]boolValue]);int priorUps=upCalls;
    setup();assert([call(@{@"action":@"burst_start",@"mode":@"65543",@"duration":@10})[@"ok"]boolValue]);pause(300);
    assert(upCalls==priorUps);assert([call(@{@"action":@"shutdown"})[@"ok"]boolValue]);assert(upCalls>priorUps);
    puts("PASS: old timer cannot affect a new epoch; shutdown releases S2 before SDK cleanup.");

    setup();manualMetadata=true;
    setFake(CrDeviceProperty_NearFar,CrNearFar_Enable);setFake(CrDeviceProperty_FocusDrivingStatus,CrFocusDrivingStatus_NotDriving);
    setFake(CrDeviceProperty_FocusPositionCurrentValue,20000);
    NSDictionary *mf=call(@{@"action":@"status"})[@"manualFocus"];
    assert([mf[@"stepEnabled"]boolValue]&&[mf[@"positionEnabled"]boolValue]&&[mf[@"position"]intValue]==20000);
    assert(([mf[@"maximum"]intValue]==65535&&[mf[@"steps"]isEqual:@[@1,@3,@7]]));
    assert(![call(@{@"action":@"focus_step",@"step":@0})[@"ok"]boolValue]);
    assert([call(@{@"action":@"focus_step",@"step":@(-7)})[@"ok"]boolValue]);assert(lastStepValue==static_cast<uint64_t>(int64_t(-7))&&focusStepsSent==1);
    assert(![call(@{@"action":@"focus_step",@"step":@1})[@"ok"]boolValue]);pause(275);
    assert([call(@{@"action":@"focus_step",@"step":@(-1)})[@"ok"]boolValue]);assert(lastStepValue==UINT64_MAX);pause(275);
    assert([call(@{@"action":@"focus_step",@"step":@1})[@"ok"]boolValue]);assert(lastStepValue==1);pause(275);
    assert(ExecuteControlCodeValue(1,CrControlCode_NearFar,65535)==CrError_Generic_InvalidParameter);
    assert(![call(@{@"action":@"focus_position",@"value":@65536})[@"ok"]boolValue]);
    auto absolute=call(@{@"action":@"focus_position",@"value":@60000});assert([absolute[@"ok"]boolValue]);
    assert([absolute[@"manualFocus"][@"moving"]boolValue]&&[absolute[@"manualFocus"][@"position"]intValue]==20000);
    assert(![call(@{@"action":@"shoot"})[@"ok"]boolValue]);assert(![call(@{@"action":@"disconnect"})[@"ok"]boolValue]);
    s.callback->OnWarning(CrWarning_FocusPosition_Result_OK);pause(200);
    {std::lock_guard<std::mutex> lock(s.mutex);assert(s.focusPending);}
    setFake(CrDeviceProperty_FocusPositionCurrentValue,59998);setFake(CrDeviceProperty_FocusDrivingStatus,CrFocusDrivingStatus_NotDriving);pause(200);
    {std::lock_guard<std::mutex> lock(s.mutex);assert(!s.focusPending&&s.focusPosition.intValue==59998);}
    assert([call(@{@"action":@"focus_position",@"value":@10000})[@"ok"]boolValue]);
    assert([call(@{@"action":@"focus_cancel"})[@"ok"]boolValue]);assert(focusCancelDowns==1&&focusCancelUps==1);pause(500);
    {std::lock_guard<std::mutex> lock(s.mutex);assert(!s.focusPending&&s.focusPosition.intValue==59998);}
    assert([call(@{@"action":@"focus_position",@"value":@10000})[@"ok"]boolValue]);
    {std::lock_guard<std::mutex> lock(s.mutex);s.focusStarted=Clock::now()-std::chrono::seconds(17);}
    pause(600);assert(focusCancelDowns==2&&focusCancelUps==2);
    {std::lock_guard<std::mutex> lock(s.mutex);assert(!s.focusPending&&s.focusTimedOut);}
    setFake(CrDeviceProperty_FocusMode,CrFocus_AF_C);
    assert(![call(@{@"action":@"focus_step",@"step":@1})[@"ok"]boolValue]);
    assert([call(@{@"action":@"shutdown"})[@"ok"]boolValue]);
    puts("PASS: MF live capabilities, signed steps/throttle, 65535 range, real-position completion, moving guard, cancellation and independent timeout recovery.");

    setup();
    {std::lock_guard<std::mutex> lock(s.mutex);s.connected=false;s.connecting=true;}
    int priorDisconnects=disconnectCalls,priorReleases=releaseCalls;
    s.callback->OnError(CrError_Connect_TimeOut);
    auto initialFailure=call(@{@"action":@"status"});
    assert(![initialFailure[@"connected"]boolValue]&&!s.handle);
    assert(disconnectCalls==priorDisconnects&&releaseCalls==priorReleases+1);
    setup();
    {std::lock_guard<std::mutex> lock(s.mutex);s.connected=false;s.connecting=true;}
    s.callback->OnConnected(DEVICE_CONNECTION_VERSION_RCP3);
    s.callback->OnError(CrError_Connect_TimeOut);
    assert(!s.callback->initialConnectFailed);
    assert([call(@{@"action":@"disconnect"})[@"ok"]boolValue]);
    assert(disconnectCalls==priorDisconnects+1&&releaseCalls==priorReleases+2);
    puts("PASS: initial OnError releases without Disconnect; previously connected session still waits for normal disconnection.");
    assert([[NSFileManager defaultManager] removeItemAtPath:testDirectory error:nil]);
}}
