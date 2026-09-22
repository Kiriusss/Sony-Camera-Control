// Opt-in hardware exercise. Never invoked by the default test suite.
// Build beside the vendor CrAdapter directory and pass --run-hardware explicitly.
#include <nlohmann/json.hpp>
#include "CrDeviceProperty.h"
#include <chrono>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iostream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>
#ifdef _WIN32
#define NOMINMAX
#include <windows.h>
#else
#include <dlfcn.h>
#endif
using Json=nlohmann::json;
namespace fs=std::filesystem;
using namespace SCRSDK;

int hardwareMain(int argc,char **argv) {
    const bool focusOnly=argc==6&&std::string(argv[1])=="--focus-only";
    if(!focusOnly&&(argc!=5||std::string(argv[1])!="--run-hardware")) {
        std::cerr<<"Usage: hardware_validation --run-hardware BRIDGE_PATH OUTPUT_JSON PHOTO_DIRECTORY\n"
                 <<"Connects one camera, downloads a single photo and a short burst, and exercises manual focus.\n"
                 <<"Or: hardware_validation --focus-only BRIDGE_PATH OUTPUT_JSON PHOTO_DIRECTORY RESTORE_POSITION\n";
        return 2;
    }
    fs::path library=fs::absolute(fs::u8path(argv[2]));
    fs::path reportPath=fs::absolute(fs::u8path(argv[3]));
    fs::path photos=fs::absolute(fs::u8path(argv[4]));
    fs::create_directories(photos);fs::create_directories(reportPath.parent_path());
#ifdef _WIN32
    SetErrorMode(SEM_FAILCRITICALERRORS|SEM_NOGPFAULTERRORBOX);
    auto module=LoadLibraryExW(library.c_str(),nullptr,LOAD_WITH_ALTERED_SEARCH_PATH);
    if(!module){std::cerr<<"Could not load bridge: "<<GetLastError()<<std::endl;return 2;}
    auto symbol=[&](const char *name){return reinterpret_cast<void*>(GetProcAddress(module,name));};
#else
    auto module=dlopen(library.c_str(),RTLD_NOW);
    if(!module){std::cerr<<dlerror()<<std::endl;return 2;}
    auto symbol=[&](const char *name){return dlsym(module,name);};
#endif
    auto request=reinterpret_cast<char *(*)(const char*)>(symbol("lr1_request"));
    auto live=reinterpret_cast<unsigned char *(*)(int*)>(symbol("lr1_copy_live_view"));
    auto release=reinterpret_cast<void(*)(void*)>(symbol("lr1_free"));
    if(!request||!live||!release)return 2;
    Json report={{"library",library.u8string()},{"photos",photos.u8string()},
                 {"phases",Json::array()},{"ok",true}};
    auto save=[&]{std::ofstream output(reportPath);output<<report.dump(2)<<std::endl;};
    auto call=[&](Json action){
        auto input=action.dump();char *raw=request(input.c_str());
        if(!raw)throw std::runtime_error("Bridge returned null");
        std::string data(raw);release(raw);return Json::parse(data);
    };
    auto record=[&](const char *phase,const Json &result){
        report["phases"].push_back(Json{{"phase",phase},{"result",result}});
        std::cout<<phase<<": "<<result.value("ok",true)<<" "<<result.value("message",std::string())<<std::endl;
        save();
    };
    auto poll=[&](const std::function<bool(const Json&)> &done,int seconds){
        auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(seconds);Json result;
        do {
            std::this_thread::sleep_for(std::chrono::milliseconds(250));
            result=call({{"action","status"}});
            if(done(result))return result;
        } while(std::chrono::steady_clock::now()<deadline);
        throw std::runtime_error("Timed out waiting for camera state");
    };
    auto require=[&](const char *phase,Json result){
        record(phase,result);
        if(!result.value("ok",false))throw std::runtime_error(std::string(phase)+" rejected: "+result.value("message",std::string()));
        return result;
    };
    auto property=[](const Json &snapshot,unsigned code){
        for(const auto &row:snapshot.at("properties"))if(row.at("code")==code)return row;
        return Json();
    };
    std::string originalMode;Json originalPosition;
    bool focusChanged=false;
    auto restoreFocus=[&]{
        if(!focusChanged)return;
        auto status=call({{"action","status"}});
        if(status["manualFocus"].value("moving",false)){
            record("focus_cleanup_cancel",call({{"action","focus_cancel"}}));
            status=poll([](const Json&s){return !s["manualFocus"].value("moving",false);},20);
        }
        if(originalPosition.is_number_integer()&&status["manualFocus"].value("positionEnabled",false)){
            auto moved=call({{"action","focus_position"},{"value",originalPosition}});
            record("focus_restore_position_request",moved);
            if(moved.value("ok",false)){
                status=poll([](const Json&s){return !s["manualFocus"].value("moving",false);},25);
                std::this_thread::sleep_for(std::chrono::milliseconds(1000));
                status=call({{"action","status"}});
                record("focus_restore_position",status);
                report["focusRestoredPosition"]=status["manualFocus"]["position"];
                report["focusRestoreExact"]=status["manualFocus"]["position"]==originalPosition;
                if(!report["focusRestoreExact"].get<bool>()){
                    report["ok"]=false;
                    report["focusRestoreNote"]="Camera completed the motion but actual lens position differs from the requested position.";
                }
            }
        }
        if(!originalMode.empty())record("focus_restore_mode",call({{"action","set_property"},{"code",CrDeviceProperty_FocusMode},{"value",originalMode}}));
        focusChanged=false;
    };
    try {
        require("initialize",call({{"action","initialize"},{"saveDirectory",photos.u8string()}}));
        auto scan=require("scan",call({{"action","scan"}}));
        if(scan.at("cameras").empty())throw std::runtime_error("No camera found");
        require("connect",call({{"action","connect"},{"index",scan["cameras"][0]["index"]}}));
        auto status=poll([](const Json &s){return s.value("connected",false)&&!s.at("properties").empty();},25);
        record("properties",status);
        if(!status.value("connected",false))throw std::runtime_error("Camera not connected");
        for(const auto &row:status["properties"])if(row["code"]==CrDeviceProperty_FocusMode)originalMode=row["value"].get<std::string>();
        originalPosition=status["manualFocus"]["position"];
        if(focusOnly)originalPosition=std::stoi(argv[5]);
        report["originalFocusMode"]=originalMode;report["originalFocusPosition"]=originalPosition;save();
        if(!focusOnly){
        bool frame=false;
        for(int attempt=0;attempt<50&&!frame;++attempt){
            int size=0;auto *bytes=live(&size);
            if(bytes&&size>4){
                std::ofstream output(photos/"live-view.jpg",std::ios::binary);output.write(reinterpret_cast<char*>(bytes),size);
                frame=true;record("live_view",{{"ok",true},{"jpegBytes",size}});
            }
            if(bytes)release(bytes);
            if(!frame)std::this_thread::sleep_for(std::chrono::milliseconds(200));
        }
        if(!frame)record("live_view",{{"ok",false},{"message","No JPEG frame returned in 10 seconds"}});

        const auto previousDownloads=status["downloads"].size();
        require("single_request",call({{"action","shoot"}}));
        status=poll([](const Json&s){return !s.value("pendingPhoto",false);},100);
        record("single_complete",status);
        if(status["downloads"].size()<=previousDownloads)throw std::runtime_error("Single capture returned no downloaded file");

        if(!status["burstModes"].empty()){
            auto modes=status["burstModes"];auto selected=modes.back();
            for(const auto &mode:modes)if(mode["value"]==std::to_string(CrDrive_Continuous_Lo))selected=mode;
            require("burst_request",call({{"action","burst_start"},{"mode",selected["value"]},{"duration",0.5}}));
            status=poll([](const Json&s){return !s.value("burstActive",false)&&!s.value("burstDraining",false);},120);
            record("burst_complete",status);
            if(status.value("burstDownloaded",0)==0)throw std::runtime_error("Burst completed without a download");
        }else record("burst",{{"ok",true},{"skipped","Camera exposes no continuous drive modes"}});
        }

        auto focusProperty=property(status,CrDeviceProperty_FocusMode);
        bool canMF=false;
        if(focusProperty.is_object())for(const auto &option:focusProperty["options"])if(option["value"]==std::to_string(CrFocus_MF))canMF=true;
        if(canMF||originalMode==std::to_string(CrFocus_MF)){
            require("focus_mf",call({{"action","set_property"},{"code",CrDeviceProperty_FocusMode},{"value",std::to_string(CrFocus_MF)}}));
            focusChanged=true;status=call({{"action","status"}});
            record("focus_capabilities",status);
            if(originalPosition.is_null())originalPosition=status["manualFocus"]["position"];
            if(status["manualFocus"].value("stepEnabled",false)){
                require("focus_near",call({{"action","focus_step"},{"step",-1}}));
                std::this_thread::sleep_for(std::chrono::milliseconds(700));
                record("focus_near_readback",call({{"action","status"}}));
                require("focus_far",call({{"action","focus_step"},{"step",1}}));
                std::this_thread::sleep_for(std::chrono::milliseconds(700));
                record("focus_far_readback",call({{"action","status"}}));
            }else record("focus_steps",{{"ok",true},{"skipped","Camera/lens does not expose NearFar support"}});
            restoreFocus();
        }else record("manual_focus",{{"ok",true},{"skipped","MF not available in current camera state"}});
    } catch(const std::exception &error) {
        report["ok"]=false;report["error"]=error.what();std::cerr<<error.what()<<std::endl;save();
    }
    try {restoreFocus();}catch(const std::exception &error){report["ok"]=false;report["focusRestoreError"]=error.what();save();}
    try {
        auto status=call({{"action","status"}});
        if(status.value("burstActive",false))record("cleanup_burst_stop",call({{"action","burst_stop"}}));
        require("disconnect",call({{"action","disconnect"}}));
        require("shutdown",call({{"action","shutdown"}}));
    } catch(const std::exception &error){report["ok"]=false;report["shutdownError"]=error.what();}
    save();return report.value("ok",false)?0:1;
}

#ifdef _WIN32
int wmain(int argc,wchar_t **wide) {
    std::vector<std::string> utf8;std::vector<char*> args;
    for(int i=0;i<argc;++i){
        int n=WideCharToMultiByte(CP_UTF8,0,wide[i],-1,nullptr,0,nullptr,nullptr);
        std::string value(n,'\0');WideCharToMultiByte(CP_UTF8,0,wide[i],-1,value.data(),n,nullptr,nullptr);
        value.pop_back();utf8.push_back(std::move(value));
    }
    for(auto &value:utf8)args.push_back(value.data());return hardwareMain(argc,args.data());
}
#else
int main(int argc,char **argv){return hardwareMain(argc,argv);}
#endif
