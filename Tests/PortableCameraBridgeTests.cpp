// Offline SDK-boundary tests. All bridge SDK entry points are mocked; the
// vendor library is linked only for property/control metadata constructors.
// LR1_BRIDGE_TESTING also disables persistent application logs.
// Offline portable SDK boundary tests. API calls are mocked; the Sony library
// supplies only the real property/control metadata constructors and destructors.
#include <nlohmann/json.hpp>
#include <filesystem>
#include <fstream>
#include <optional>
#include <random>
#include <iomanip>
#include <sstream>
#include <ctime>
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
#include <iostream>
#include <cassert>
#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#else
#include <fcntl.h>
#include <unistd.h>
#endif
#include "CrDeviceProperty.h"
#define private public
#include "CrControlCode.h"
#undef private
// The API and enumeration both use Release; keep their mock names consistent.
#define Release MockRelease
#include "ICrCameraObjectInfo.h"
#undef Release
#include "CameraRemote_SDK.h"
#include "IDeviceCallback.h"
#define LR1_BRIDGE_TESTING 1
#define EnumCameraObjects MockEnumCameraObjects
#define GetFingerprint MockGetFingerprint
#define GetLiveViewImage MockGetLiveViewImage
#define GetLiveViewImageInfo MockGetLiveViewImageInfo
#define SetDeviceSetting MockSetDeviceSetting
#define GetSDKVersion MockGetSDKVersion
#define Init MockInit
#define Connect MockConnect
#define Release MockRelease
#define GetSelectDeviceProperties MockGetSelectDeviceProperties
#define GetDeviceProperties MockGetDeviceProperties
#define ReleaseDeviceProperties MockReleaseDeviceProperties
#define SetDeviceProperty MockSetDeviceProperty
#define SendCommand MockSendCommand
#define GetSelectControlCode MockGetSelectControlCode
#define ReleaseControlCodes MockReleaseControlCodes
#define ExecuteControlCodeValue MockExecuteControlCodeValue
#define SetSaveInfo MockSetSaveInfo
#define Disconnect MockDisconnect
#define ReleaseDevice MockReleaseDevice
namespace SCRSDK {
extern "C" CrError EnumCameraObjects(ICrEnumCameraObjectInfo**,CrInt8u);
extern "C" CrError GetFingerprint(ICrCameraObjectInfo*,char*,CrInt32u*);
extern "C" CrError GetLiveViewImage(CrDeviceHandle,CrImageDataBlock*);
extern "C" CrError GetLiveViewImageInfo(CrDeviceHandle,CrImageInfo*);
extern "C" CrError SetDeviceSetting(CrDeviceHandle,CrInt32u,CrInt32u);
extern "C" CrInt32u GetSDKVersion();
extern "C" bool Init(CrInt32u=0);
extern "C" CrError Connect(ICrCameraObjectInfo *info,IDeviceCallback *callback,CrDeviceHandle *handle,CrSdkControlMode,CrReconnectingSet,const char*,const char*,const char*,CrInt32u,const CrInt16u * =nullptr);
extern "C" bool Release();
extern "C" CrError GetSelectDeviceProperties(CrDeviceHandle,CrInt32u n,CrInt32u *codes,CrDeviceProperty **out,CrInt32 *count);
extern "C" CrError GetDeviceProperties(CrDeviceHandle handle,CrDeviceProperty **out,CrInt32 *count);
extern "C" CrError ReleaseDeviceProperties(CrDeviceHandle,CrDeviceProperty *p);
extern "C" CrError SetDeviceProperty(CrDeviceHandle,CrDeviceProperty *p);
extern "C" CrError SendCommand(CrDeviceHandle,CrInt32u command,CrCommandParam value);
extern "C" CrError GetSelectControlCode(CrDeviceHandle,CrControlCode code,CrControlCodeInfo **out);
extern "C" CrError ReleaseControlCodes(CrDeviceHandle,CrControlCodeInfo *info);
extern "C" CrError ExecuteControlCodeValue(CrDeviceHandle,CrControlCode code,CrInt64u value);
extern "C" CrError SetSaveInfo(CrDeviceHandle,CrChar *path,CrChar*,CrInt32);
extern "C" CrError Disconnect(CrDeviceHandle);
extern "C" CrError ReleaseDevice(CrDeviceHandle);
}
#include "../Sources/Portable/CameraBridge.cpp"
#if defined(_UNICODE) || defined(UNICODE)
#define TEST_TEXT(s) L##s
#else
#define TEST_TEXT(s) s
#endif


#include <cassert>
#include <iostream>
static std::mutex fakeMutex;
static std::map<uint32_t,uint64_t> fakeValues;
static std::set<uint32_t> fakeUnsupported,fakeReadOnly;
static uint32_t fakeReadFailure=0;
static bool allowMockConnect=false;
static int mockConnectCalls=0;
static std::atomic<int> downCalls{0},upCalls{0},releaseCalls{0},disconnectCalls{0};
static std::string lastSavePath;
static std::string testDirectory;
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
extern "C" CrError Connect(ICrCameraObjectInfo *info,IDeviceCallback *callback,CrDeviceHandle *handle,CrSdkControlMode,CrReconnectingSet,const char*,const char*,const char*,CrInt32u,const CrInt16u*){
    assert(allowMockConnect&&"Unexpected mock connection");assert(text(info->GetModel())=="ILCE-7M4");
    ++mockConnectCalls;*handle=1;callback->OnConnected(DEVICE_CONNECTION_VERSION_RCP3);return 0;
}
extern "C" bool Release(){return true;}
extern "C" CrError GetSelectDeviceProperties(CrDeviceHandle,CrInt32u n,CrInt32u *codes,CrDeviceProperty **out,CrInt32 *count){
    std::lock_guard<std::mutex> lock(fakeMutex);
    for(unsigned i=0;i<n;++i)if(codes[i]==fakeReadFailure){*out=nullptr;*count=0;return CrError_Generic_Unknown;}
    *out=new CrDeviceProperty[n];*count=(int)n;
    for(unsigned i=0;i<n;++i){auto &p=(*out)[i];p.SetCode(codes[i]);p.SetValueType(CrDataType_UInt32);p.SetPropertyEnableFlag(CrEnableValue_True);p.SetPropertyVariableFlag(CrEnableValue_Variable);p.SetCurrentValue(fakeValues[codes[i]]);
        if(fakeUnsupported.count(codes[i]))p.SetPropertyEnableFlag(CrEnableValue_NotSupported);
        if(fakeReadOnly.count(codes[i])){p.SetPropertyEnableFlag(CrEnableValue_DisplayOnly);p.SetPropertyVariableFlag(CrEnableValue_Invariable);}
        if(manualMetadata&&(codes[i]==CrDeviceProperty_FocusPositionSetting||codes[i]==CrDeviceProperty_FocusPositionCurrentValue)) {
            uint16_t range[]={0,65535,1};p.SetValueType(CrDataType_UInt16Range);p.SetValueSize(sizeof(range));auto *owned=new uint8_t[sizeof(range)];memcpy(owned,range,sizeof(range));p.SetValues(owned);
        }
    }
    return 0;
}
extern "C" CrError GetDeviceProperties(CrDeviceHandle handle,CrDeviceProperty **out,CrInt32 *count){
    std::vector<uint32_t> codes;{std::lock_guard<std::mutex> lock(fakeMutex);for(const auto &v:fakeValues)codes.push_back(v.first);}
    return GetSelectDeviceProperties(handle,(uint32_t)codes.size(),codes.data(),out,count);
}
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
extern "C" CrError SetSaveInfo(CrDeviceHandle,CrChar *path,CrChar*,CrInt32){lastSavePath=text(path);return 0;}
extern "C" CrError Disconnect(CrDeviceHandle){++disconnectCalls;state().callback->OnDisconnected(0);return 0;}
extern "C" CrError ReleaseDevice(CrDeviceHandle){std::lock_guard<std::mutex> lock(fakeMutex);assert(fakeValues[CrDeviceProperty_S2]==CrLockIndicator_Unlocked);++releaseCalls;return 0;}
}
static void setFake(uint32_t code,uint64_t value){std::lock_guard<std::mutex> lock(fakeMutex);fakeValues[code]=value;}
static Json call(const Json &request) {
    std::string input=request.dump();char *raw=lr1_request(input.c_str());assert(raw);
    Json result=Json::parse(raw);lr1_free(raw);return result;
}
static void setup(){
    auto &s=state();std::lock_guard<std::mutex> lock(s.mutex);++s.epoch;s.initialized=s.connected=s.configured=true;s.connecting=false;s.handle=1;s.pendingPhoto=false;
    s.burstActive=s.burstDraining=s.burstReleasePending=false;s.configurationError="";s.configurationInputs.clear();s.noCardConfirmed=false;
    s.saveDirectory=testDirectory;
    auto callback=std::make_unique<Callback>(s.epoch);s.callback=callback.get();s.callbacks.push_back(std::move(callback));
    setFake(CrDeviceProperty_ExposureProgramMode,CrExposure_Auto);setFake(CrDeviceProperty_ShutterSpeed,(1u<<16)|160);
    setFake(CrDeviceProperty_StillImageStoreDestination,CrStillImageStoreDestination_HostPC);setFake(CrDeviceProperty_ReleaseWithoutCard,CrReleaseWithoutCard_Enable);
    setFake(CrDeviceProperty_DriveMode,CrDrive_Single);setFake(CrDeviceProperty_FileType,CrFileType_RawHeif);setFake(CrDeviceProperty_FocusMode,CrFocus_MF);
    setFake(CrDeviceProperty_SnapshotInfo,0);setFake(CrDeviceProperty_S1,CrLockIndicator_Unlocked);setFake(CrDeviceProperty_S2,CrLockIndicator_Unlocked);
}
static void downloaded(const std::string &name) {
    std::string dir;Callback *callback;
    {std::lock_guard<std::mutex> lock(state().mutex);dir=state().burstDirectory;callback=state().callback;}
    auto path=fs::u8path(dir)/fs::u8path(name);
    {std::ofstream file(path,std::ios::binary);file<<"test-file";}
    auto native=sdkPath(path);callback->OnCompleteDownload(native.data(),0xFFFFFFFF);
}
static void captured(){state().callback->OnWarning(CrNotify_Captured_Event);}
static void pause(int ms){std::this_thread::sleep_for(std::chrono::milliseconds(ms));}
class MockCamera final:public ICrCameraObjectInfo {
public:
    void Release() override {}
    CrChar *GetName() const override{return const_cast<CrChar*>(TEST_TEXT("Test camera"));}
    CrInt32u GetNameSize() const override{return 12;}
    CrChar *GetModel() const override{return const_cast<CrChar*>(TEST_TEXT("ILCE-7M4"));}
    CrInt32u GetModelSize() const override{return 9;}
    CrInt16 GetUsbPid() const override{return 0;}
    CrInt8u *GetId() const override{return nullptr;}
    CrInt32u GetIdSize() const override{return 0;}
    CrInt32u GetIdType() const override{return 0;}
    CrInt32u GetConnectionStatus() const override{return 0;}
    CrChar *GetConnectionTypeName() const override{return const_cast<CrChar*>(TEST_TEXT("USB"));}
    CrChar *GetAdaptorName() const override{return const_cast<CrChar*>(TEST_TEXT("Mock"));}
    CrChar *GetGuid() const override{return nullptr;}
    CrChar *GetPairingNecessity() const override{return nullptr;}
    CrInt16u GetAuthenticationState() const override{return 0;}
    CrInt32u GetSSHsupport() const override{return 0;}
    CrInt32u GetIPAddress() const override{return 0;}
    CrChar *GetIPAddressChar() const override{return nullptr;}
    CrInt32u GetIPAddressCharSize() const override{return 0;}
    CrInt8u *GetMACAddress() const override{return nullptr;}
    CrInt32u GetMACAddressSize() const override{return 0;}
    CrChar *GetMACAddressChar() const override{return nullptr;}
    CrInt32u GetMACAddressCharSize() const override{return 0;}
};
class MockEnumeration final:public ICrEnumCameraObjectInfo {
    MockCamera camera;
public:
    CrInt32u GetCount() const override{return 1;}
    const ICrCameraObjectInfo *GetCameraObjectInfo(CrInt32u index) const override{return index==0?&camera:nullptr;}
    void Release() override {}
};
int main(){{
    auto directory=fs::temp_directory_path()/fs::u8path("LR1-CameraBridgeTests-中文-"+uniqueSuffix());
    testDirectory=directory.u8string();assert(fs::create_directories(directory));
    setup();auto &s=state();
    for(const Json &invalid:Json::array({-1,4294967557ULL,1.5,"261",nullptr}))
        assert(!call(Json{{"action","set_property"},{"code",invalid},{"value","1"}})["ok"].get<bool>());
    for(const Json &invalid:Json::array({"garbage",false,nullptr,Json::array(),-1,0,11})) {
        int prior=downCalls;
        assert(!call(Json{{"action","burst_start"},{"mode","65543"},{"duration",invalid}})["ok"].get<bool>());
        assert(downCalls==prior);
    }
    auto start=call(Json{{"action","burst_start"},{"mode","65543"},{"duration",0.5}});assert((start["ok"]).get<bool>()&&(start["burstActive"]).get<bool>());
    for(const char *key:{"burstActive","burstDraining","burstCaptured","burstDownloaded","burstFiles","burstModes","burstElapsed","burstStatus","burstRecoverable"})assert(start.contains(key));
    assert(!(call(Json{{"action","set_property"},{"code",257},{"value","1"}})["ok"]).get<bool>());
    setFake(CrDeviceProperty_SnapshotInfo,1);captured();captured();
    downloaded("DSC00001.ARW");downloaded("DSC00002.HIF");
    {std::lock_guard<std::mutex> lock(s.mutex);assert(s.burstFiles==2&&s.burstDownloaded==0&&s.pendingPhoto);}
    downloaded("DSC00002.ARW");downloaded("DSC00001.HIF");downloaded("DSC00001.ARW");
    {std::lock_guard<std::mutex> lock(s.mutex);assert(s.burstDownloaded==2&&s.burstFiles==4&&s.burstActive&&s.pendingPhoto);}
    pause(850); // No status polling: the independent timer must stop S2.
    assert(upCalls>0);{std::lock_guard<std::mutex> lock(s.mutex);assert(!s.burstActive&&s.burstDraining&&s.pendingPhoto);}
    pause(1300);{std::lock_guard<std::mutex> lock(s.mutex);assert(s.burstDraining);}
    setFake(CrDeviceProperty_SnapshotInfo,0);pause(1000);
    {std::lock_guard<std::mutex> lock(s.mutex);assert(!s.burstDraining&&!s.pendingPhoto&&s.burstDownloaded==2);assert((lastSavePath == s.saveDirectory));}
    {std::lock_guard<std::mutex> lock(fakeMutex);assert(fakeValues[CrDeviceProperty_DriveMode]==CrDrive_Single);}
    puts("PASS: Auto mode, out-of-order RAW/HIF groups, duplicate callbacks, independent timer, queue-empty completion, Single/directory restore.");

    assert((call(Json{{"action","burst_start"},{"mode","65543"},{"duration",0.5}})["ok"]).get<bool>());captured();downloaded("DSC00003.ARW");pause(2600);
    {std::lock_guard<std::mutex> lock(s.mutex);assert(s.burstDraining&&s.pendingPhoto&&s.burstDownloaded==0);}
    s.callback->OnWarning(CrWarning_GetImage_Failed);
    auto failed=call(Json{{"action","status"}});assert((failed["burstRecoverable"]).get<bool>()&&(failed["pendingPhoto"]).get<bool>());
    assert((call(Json{{"action","disconnect"}})["ok"]).get<bool>());assert(releaseCalls==1);
    puts("PASS: missing HIF never completes; explicit transfer failure enables safe incomplete-disconnect recovery.");

    setup();assert((call(Json{{"action","burst_start"},{"mode","65543"},{"duration",10}})["ok"]).get<bool>());
    assert((call(Json{{"action","disconnect"}})["ok"]).get<bool>());int priorUps=upCalls;
    setup();assert((call(Json{{"action","burst_start"},{"mode","65543"},{"duration",10}})["ok"]).get<bool>());pause(300);
    assert(upCalls==priorUps);assert((call(Json{{"action","shutdown"}})["ok"]).get<bool>());assert(upCalls>priorUps);
    puts("PASS: old timer cannot affect a new epoch; shutdown releases S2 before SDK cleanup.");

    setup();manualMetadata=true;
    setFake(CrDeviceProperty_NearFar,CrNearFar_Enable);setFake(CrDeviceProperty_FocusDrivingStatus,CrFocusDrivingStatus_NotDriving);
    setFake(CrDeviceProperty_FocusPositionCurrentValue,20000);
    Json mf=call(Json{{"action","status"}})["manualFocus"];
    assert((mf["stepEnabled"]).get<bool>()&&(mf["positionEnabled"]).get<bool>()&&(mf["position"]).get<int>()==20000);
    assert(((mf["maximum"]).get<int>()==65535&&(mf["steps"] == Json::array({1,3,7}))));
    assert(!(call(Json{{"action","focus_step"},{"step",0}})["ok"]).get<bool>());
    assert((call(Json{{"action","focus_step"},{"step",(-7)}})["ok"]).get<bool>());assert(lastStepValue==static_cast<uint64_t>(int64_t(-7))&&focusStepsSent==1);
    assert(!(call(Json{{"action","focus_step"},{"step",1}})["ok"]).get<bool>());pause(275);
    assert((call(Json{{"action","focus_step"},{"step",(-1)}})["ok"]).get<bool>());assert(lastStepValue==UINT64_MAX);pause(275);
    assert((call(Json{{"action","focus_step"},{"step",1}})["ok"]).get<bool>());assert(lastStepValue==1);pause(275);
    assert(ExecuteControlCodeValue(1,CrControlCode_NearFar,65535)==CrError_Generic_InvalidParameter);
    assert(!(call(Json{{"action","focus_position"},{"value",65536}})["ok"]).get<bool>());
    auto absolute=call(Json{{"action","focus_position"},{"value",60000}});assert((absolute["ok"]).get<bool>());
    assert((absolute["manualFocus"]["moving"]).get<bool>()&&(absolute["manualFocus"]["position"]).get<int>()==20000);
    assert(!(call(Json{{"action","shoot"}})["ok"]).get<bool>());assert(!(call(Json{{"action","disconnect"}})["ok"]).get<bool>());
    s.callback->OnWarning(CrWarning_FocusPosition_Result_OK);pause(200);
    {std::lock_guard<std::mutex> lock(s.mutex);assert(s.focusPending);}
    setFake(CrDeviceProperty_FocusPositionCurrentValue,59998);setFake(CrDeviceProperty_FocusDrivingStatus,CrFocusDrivingStatus_NotDriving);pause(200);
    {std::lock_guard<std::mutex> lock(s.mutex);assert(!s.focusPending&&*s.focusPosition==59998);}
    assert((call(Json{{"action","focus_position"},{"value",10000}})["ok"]).get<bool>());
    assert((call(Json{{"action","focus_cancel"}})["ok"]).get<bool>());assert(focusCancelDowns==1&&focusCancelUps==1);pause(500);
    {std::lock_guard<std::mutex> lock(s.mutex);assert(!s.focusPending&&*s.focusPosition==59998);}
    assert((call(Json{{"action","focus_position"},{"value",10000}})["ok"]).get<bool>());
    {std::lock_guard<std::mutex> lock(s.mutex);s.focusStarted=Clock::now()-std::chrono::seconds(17);}
    pause(600);assert(focusCancelDowns==2&&focusCancelUps==2);
    {std::lock_guard<std::mutex> lock(s.mutex);assert(!s.focusPending&&s.focusTimedOut);}
    setFake(CrDeviceProperty_FocusMode,CrFocus_AF_C);
    assert(!(call(Json{{"action","focus_step"},{"step",1}})["ok"]).get<bool>());
    assert((call(Json{{"action","shutdown"}})["ok"]).get<bool>());
    puts("PASS: MF live capabilities, signed steps/throttle, 65535 range, real-position completion, moving guard, cancellation and independent timeout recovery.");

    setup();
    {std::lock_guard<std::mutex> lock(s.mutex);s.connected=false;s.connecting=true;}
    int priorDisconnects=disconnectCalls,priorReleases=releaseCalls;
    s.callback->OnError(CrError_Connect_TimeOut);
    auto initialFailure=call(Json{{"action","status"}});
    assert(!(initialFailure["connected"]).get<bool>()&&!s.handle);
    assert(disconnectCalls==priorDisconnects&&releaseCalls==priorReleases+1);
    setup();
    {std::lock_guard<std::mutex> lock(s.mutex);s.connected=false;s.connecting=true;}
    s.callback->OnConnected(DEVICE_CONNECTION_VERSION_RCP3);
    s.callback->OnError(CrError_Connect_TimeOut);
    assert(!s.callback->initialConnectFailed);
    assert((call(Json{{"action","disconnect"}})["ok"]).get<bool>());
    assert(disconnectCalls==priorDisconnects+1&&releaseCalls==priorReleases+2);
    puts("PASS: initial OnError releases without Disconnect; previously connected session still waits for normal disconnection.");

    setup();assert((call(Json{{"action","shutdown"}})["ok"]).get<bool>());
    MockEnumeration enumeration;
    {std::lock_guard<std::mutex> lock(s.mutex);s.initialized=true;s.enumeration=&enumeration;}
    allowMockConnect=true;
    auto connection=call(Json{{"action","connect"},{"index",0}});
    assert((connection["ok"]).get<bool>()&&(connection["connected"]).get<bool>()&&mockConnectCalls==1);
    assert((connection["cameraName"] == "ILCE-7M4"));
    fakeUnsupported.insert(CrDeviceProperty_ReleaseWithoutCard);
    auto capability=call(Json{{"action","status"}});
    assert((capability["photoReady"]).get<bool>()&&!(capability["noCardConfirmed"]).get<bool>());
    assert(!(call(Json{{"action","movie_start"}})["ok"]).get<bool>());
    int priorDowns=downCalls;
    fakeUnsupported.insert(CrDeviceProperty_S2);
    assert(!(call(Json{{"action","burst_start"},{"mode","65543"},{"duration",0.5}})["ok"]).get<bool>());
    assert(downCalls==priorDowns);fakeUnsupported.erase(CrDeviceProperty_S2);
    fakeUnsupported.insert(CrDeviceProperty_SnapshotInfo);
    assert(!(call(Json{{"action","burst_start"},{"mode","65543"},{"duration",0.5}})["ok"]).get<bool>());
    assert(downCalls==priorDowns);fakeUnsupported.erase(CrDeviceProperty_SnapshotInfo);
    puts("PASS: non-LR1 enumerated camera connects; absent optional no-card setting does not block photos; missing burst status never releases shutter.");

    // Simulate changing the camera body switch, without using set_property.
    setFake(CrDeviceProperty_ExposureProgramMode,CrExposure_Movie_P);
    call(Json{{"action","status"}});capability=call(Json{{"action","status"}});
    assert(!(capability["photoReady"]).get<bool>()&&(capability["connected"]).get<bool>());
    auto logCount=(capability["logs"]).size();
    assert((call(Json{{"action","status"}})["logs"]).size()==logCount);
    setFake(CrDeviceProperty_ExposureProgramMode,CrExposure_Auto);
    call(Json{{"action","status"}});capability=call(Json{{"action","status"}});
    assert((capability["photoReady"]).get<bool>());
    fakeReadFailure=CrDeviceProperty_ReleaseWithoutCard;
    {std::lock_guard<std::mutex> lock(s.mutex);s.configured=false;}
    assert(!(call(Json{{"action","status"}})["photoReady"]).get<bool>());
    fakeReadFailure=0;fakeUnsupported.clear();
    {std::lock_guard<std::mutex> lock(s.mutex);s.configured=false;}
    capability=call(Json{{"action","status"}});
    assert((capability["photoReady"]).get<bool>()&&(capability["noCardConfirmed"]).get<bool>());
    puts("PASS: external Movie/Still changes recover photo readiness; unchanged failure is not logged repeatedly; SDK errors are not mistaken for absent settings.");

    std::string configurationMessage="";
    setFake(CrDeviceProperty_FileType,CrFileType_RawJpeg);
    setFake(CrDeviceProperty_RAW_J_PC_Save_Image,CrPropertyRAWJPCSaveImage_JPEGOnly);
    setFake(CrDeviceProperty_Still_Image_Trans_Size,CrPropertyStillImageTransSize_SmallSize);
    assert(configurePC(&configurationMessage));
    assert(fakeValues[CrDeviceProperty_RAW_J_PC_Save_Image]==CrPropertyRAWJPCSaveImage_RAWAndJPEG);
    assert(fakeValues[CrDeviceProperty_Still_Image_Trans_Size]==CrPropertyStillImageTransSize_Original);
    setFake(CrDeviceProperty_FileType,CrFileType_RawHeif);
    assert(configurePC(&configurationMessage));
    assert(fakeValues[CrDeviceProperty_RAW_J_PC_Save_Image]==CrPropertyRAWJPCSaveImage_RAWAndHEIF);
    fakeReadOnly.insert(CrDeviceProperty_RAW_J_PC_Save_Image);
    fakeReadOnly.insert(CrDeviceProperty_Still_Image_Trans_Size);
    setFake(CrDeviceProperty_RAW_J_PC_Save_Image,CrPropertyRAWJPCSaveImage_JPEGOnly);
    assert(configurePC(&configurationMessage));
    assert(fakeValues[CrDeviceProperty_RAW_J_PC_Save_Image]==CrPropertyRAWJPCSaveImage_JPEGOnly);
    assert((call(Json{{"action","shutdown"}})["ok"]).get<bool>());
    puts("PASS: writable transfer format and image size are aligned; inactive LR1 transfer settings remain untouched.");
    assert(fs::remove_all(directory)>0);
}}
