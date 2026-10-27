// xm5 — tiny CLI for Sony WH-1000XM5 noise control, built on libmdr (mos9527/SonyHeadphonesClient).
//
//   xm5 status            print noise mode, ambient level, playback status
//   xm5 nc                noise cancelling
//   xm5 ambient [0-20]    ambient sound (default 20)
//   xm5 off               noise control off
//   xm5 toggle            NC -> pause + ambient; ambient/off -> NC + resume (if it was playing)
//
// Env: XM5_ADDR=AA:BB:..  pick a device by MAC (default: first paired device whose name contains "1000XM")
//      XM5_DEBUG=1        verbose logging

#import <Foundation/Foundation.h>
#include <mdr-bt/ConnectionMacOS.h>
#include <mdr-c/Headphones.h>

#include <mach-o/dyld.h>
#include <spawn.h>
#include <sys/wait.h>

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

using Clock = std::chrono::steady_clock;

static bool gDebug = false;
#define LOG(...) do { if (gDebug) { fprintf(stderr, "[xm5] " __VA_ARGS__); fputc('\n', stderr); } } while (0)

static int Fail(const char* what, MDRResult r, MDRConnection* conn = nullptr)
{
    fprintf(stderr, "xm5: %s failed: %s%s%s\n", what, mdrResultString(r), conn ? " — " : "",
            conn ? mdrConnectionGetLastError(conn) : "");
    return 1;
}

static std::string StateFile()
{
    const char* tmp = getenv("TMPDIR");
    return std::string(tmp ? tmp : "/tmp/") + "xm5-was-playing";
}

static bool FindDevice(MDRConnection* conn, std::string& outAddr, std::string& outName)
{
    if (const char* env = getenv("XM5_ADDR"))
    {
        outAddr = env, outName = env;
        return true;
    }
    const auto deadline = Clock::now() + std::chrono::seconds(5);
    while (Clock::now() < deadline)
    {
        MDRDeviceInfo* list = nullptr;
        int count = 0;
        MDRResult r = mdrConnectionGetDevicesList(conn, &list, &count);
        if (r == MDR_RESULT_OK)
        {
            bool found = false;
            for (int i = 0; i < count && !found; ++i)
            {
                LOG("paired: %s (%s)", list[i].szDeviceName, list[i].szDeviceMacAddress);
                if (strstr(list[i].szDeviceName, "1000XM"))
                    outAddr = list[i].szDeviceMacAddress, outName = list[i].szDeviceName, found = true;
            }
            mdrConnectionFreeDevicesList(conn, &list);
            return found;
        }
        if (r != MDR_RESULT_INPROGRESS)
            return false;
        [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    return false;
}

// Pump I/O until `want` is seen (or any event if want == MDR_EVENT_NONE and ready). Returns false on timeout/error.
static bool WaitFor(MDRHeadphones* hp, MDRConnection* conn, MDREvent want, int timeoutMs)
{
    const auto deadline = Clock::now() + std::chrono::milliseconds(timeoutMs);
    while (Clock::now() < deadline)
    {
        // IOBluetooth delivers data/write-completions on the main run loop; mdrConnectionPoll returns early when
        // no write is pending, so pump the run loop ourselves.
        [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
        MDREvent ev = MDR_EVENT_NONE;
        MDRResult r;
        while ((r = mdrHeadphonesPoll(hp, &ev)) == MDR_RESULT_OK && ev != MDR_EVENT_NONE)
        {
            LOG("event %u", ev);
            if (ev == MDR_EVENT_NEED_SYNC && mdrHeadphonesIsReady(hp))
                mdrHeadphonesRequestSync(hp);
            if (ev == want)
                return true;
        }
        if (r != MDR_RESULT_OK && r != MDR_RESULT_INPROGRESS)
        {
            fprintf(stderr, "xm5: poll failed: %s\n", mdrResultString(r));
            return false;
        }
    }
    fprintf(stderr, "xm5: timed out waiting for event %u\n", want);
    return false;
}

static const char* ModeName(const MDRNoiseControl& nc)
{
    switch (nc.mode)
    {
    case MDR_NOISE_MODE_OFF: return "off";
    case MDR_NOISE_MODE_CANCELLING: return "nc";
    case MDR_NOISE_MODE_AMBIENT: return "ambient";
    default: return "unknown";
    }
}

static const char* PlaybackName(MDRPlaybackStatus s)
{
    switch (s)
    {
    case MDR_PLAYBACK_STOPPED: return "stopped";
    case MDR_PLAYBACK_PLAYING: return "playing";
    case MDR_PLAYBACK_PAUSED: return "paused";
    default: return "unknown";
    }
}

static bool Apply(MDRHeadphones* hp, MDRConnection* conn)
{
    MDRResult r = mdrHeadphonesRequestCommit(hp);
    if (r != MDR_RESULT_OK && r != MDR_RESULT_INPROGRESS)
        return Fail("commit", r), false;
    return WaitFor(hp, conn, MDR_EVENT_APPLY_COMPLETE, 4000);
}

static bool SetNoise(MDRHeadphones* hp, MDRConnection* conn, MDRNoiseControl nc, MDRNoiseMode mode, uint32_t level)
{
    nc.mode = mode;
    if (mode == MDR_NOISE_MODE_AMBIENT)
        nc.ambient_level = level, nc.focus_on_voice = MDR_FALSE;
    nc.changing_asm_level = MDR_FALSE;
    MDRResult r = mdrHeadphonesSetNoiseControl(hp, &nc);
    if (r != MDR_RESULT_OK)
        return Fail("set noise control", r), false;
    return Apply(hp, conn);
}

static bool SendPlayback(MDRHeadphones* hp, MDRConnection* conn, MDRPlaybackAction action)
{
    MDRPlaybackCommand cmd{action};
    MDRResult r = mdrHeadphonesSendPlaybackCommand(hp, &cmd);
    if (r != MDR_RESULT_OK)
        return Fail("playback command", r), false;
    return Apply(hp, conn);
}

static int Run(int argc, const char** argv)
{
    gDebug = getenv("XM5_DEBUG") != nullptr;
    const std::string cmd = argc > 1 ? argv[1] : "status";
    if (cmd != "status" && cmd != "nc" && cmd != "ambient" && cmd != "off" && cmd != "toggle")
    {
        fprintf(stderr, "usage: xm5 [status|nc|ambient [0-20]|off|toggle]\n");
        return 2;
    }
    uint32_t level = argc > 2 ? (uint32_t)std::clamp(atoi(argv[2]), 0, 20) : 20;

    MDRConnectionMacOS* backend = mdrConnectionMacOSCreate();
    MDRConnection* conn = mdrConnectionMacOSGet(backend);

    std::string addr, name;
    if (!FindDevice(conn, addr, name))
    {
        fprintf(stderr, "xm5: no paired WH-1000XM* found (set XM5_ADDR to override)\n");
        return 1;
    }
    LOG("using %s (%s)", name.c_str(), addr.c_str());

    MDRHeadphones* hp = nullptr;
    // Runs on every exit path: the backend closes the RFCOMM channel from the main queue, so pump it before exiting,
    // or the headphones keep the stale channel open and the next invocation's connect times out.
    struct Teardown
    {
        MDRHeadphones*& hp;
        MDRConnection* conn;
        ~Teardown()
        {
            if (hp)
                mdrHeadphonesDestroy(hp);
            mdrConnectionDisconnect(conn);
            [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.15]];
        }
    } teardown{hp, conn};

    // Right after a previous invocation the headphones may still be tearing down the old channel; retry.
    MDRResult r = MDR_RESULT_ERROR_NO_CONNECTION;
    for (int attempt = 0; attempt < 3 && r != MDR_RESULT_OK; ++attempt)
    {
        if (attempt > 0)
        {
            LOG("connect attempt %d failed (%s), retrying", attempt, mdrResultString(r));
            mdrConnectionDisconnect(conn);
            [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
        }
        r = mdrConnectionConnect(conn, addr.c_str(), MDR_SERVICE_UUID_V2);
        if (r == MDR_RESULT_OK || r == MDR_RESULT_INPROGRESS)
            r = mdrConnectionPoll(conn, 2000);
    }
    if (r != MDR_RESULT_OK)
        return Fail("connect", r, conn);
    LOG("rfcomm connected");

    if ((r = mdrHeadphonesCreate(MDR_ABI_VERSION, conn, MDR_PROTOCOL_V2, &hp)) != MDR_RESULT_OK)
        return Fail("create", r);
    if (gDebug)
        mdrHeadphonesSetPacketCallback(hp, [](void*, MDRPacketDirection dir, const unsigned char* f, int n) {
            fprintf(stderr, "[xm5] %6.3f %s %3d:", [NSProcessInfo processInfo].systemUptime, dir == MDR_PACKET_DIRECTION_TX ? "TX" : "RX", n);
            for (int i = 0; i < n && i < 24; ++i) fprintf(stderr, " %02x", f[i]);
            fputc('\n', stderr);
        }, nullptr);
    if ((r = mdrHeadphonesRequestInit(hp)) != MDR_RESULT_OK && r != MDR_RESULT_INPROGRESS)
        return Fail("init", r);
    if (!WaitFor(hp, conn, MDR_EVENT_INITIALIZE_COMPLETE, 6000))
        return 1;
    LOG("initialized");

    MDRNoiseControl nc{};
    if ((r = mdrHeadphonesGetNoiseControl(hp, MDR_PROPERTY_CURRENT, &nc)) != MDR_RESULT_OK)
        return Fail("get noise control", r);
    MDRPlayback pb{};
    mdrHeadphonesGetPlayback(hp, MDR_PROPERTY_CURRENT, &pb);

    int rc = 0;
    if (cmd == "status")
    {
        printf("mode=%s ambient_level=%u playback=%s\n", ModeName(nc), nc.ambient_level, PlaybackName(pb.status));
    }
    else if (cmd == "nc")
        rc = SetNoise(hp, conn, nc, MDR_NOISE_MODE_CANCELLING, 0) ? 0 : 1;
    else if (cmd == "off")
        rc = SetNoise(hp, conn, nc, MDR_NOISE_MODE_OFF, 0) ? 0 : 1;
    else if (cmd == "ambient")
        rc = SetNoise(hp, conn, nc, MDR_NOISE_MODE_AMBIENT, level) ? 0 : 1;
    else // toggle
    {
        const std::string state = StateFile();
        if (nc.mode == MDR_NOISE_MODE_CANCELLING)
        {
            const bool playing = pb.status == MDR_PLAYBACK_PLAYING;
            if (FILE* f = fopen(state.c_str(), "w"))
                fputs(playing ? "1" : "0", f), fclose(f);
            if (playing && !SendPlayback(hp, conn, MDR_PLAYBACK_PAUSE))
                rc = 1;
            if (!SetNoise(hp, conn, nc, MDR_NOISE_MODE_AMBIENT, level))
                rc = 1;
            printf("ambient%s\n", playing ? " (paused)" : "");
        }
        else
        {
            bool wasPlaying = false;
            if (FILE* f = fopen(state.c_str(), "r"))
                wasPlaying = fgetc(f) == '1', fclose(f), remove(state.c_str());
            if (!SetNoise(hp, conn, nc, MDR_NOISE_MODE_CANCELLING, 0))
                rc = 1;
            if (wasPlaying && pb.status != MDR_PLAYBACK_PLAYING && !SendPlayback(hp, conn, MDR_PLAYBACK_PLAY))
                rc = 1;
            printf("nc%s\n", wasPlaying ? " (resumed)" : "");
        }
    }

    return rc;
}

// TCC attributes Bluetooth access to the "responsible" process (Terminal, BetterTouchTool, ...), which usually
// lacks NSBluetoothAlwaysUsageDescription. Re-spawn ourselves disclaiming responsibility so xm5 itself — with its
// embedded Info.plist — is what gets asked for (and remembered with) the Bluetooth permission.
extern "C" int responsibility_spawnattrs_setdisclaim(posix_spawnattr_t* attrs, int disclaim);
extern char** environ;

static int RespawnDisclaimed(const char** argv)
{
    char path[PATH_MAX];
    uint32_t size = sizeof(path);
    if (_NSGetExecutablePath(path, &size) != 0)
        return -1;
    setenv("XM5_DISCLAIMED", "1", 1);
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    responsibility_spawnattrs_setdisclaim(&attr, 1);
    pid_t pid;
    int err = posix_spawn(&pid, path, nullptr, &attr, (char* const*)argv, environ);
    posix_spawnattr_destroy(&attr);
    if (err != 0)
        return -1;
    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}

int main(int argc, const char** argv)
{
    if (!getenv("XM5_DISCLAIMED"))
    {
        int rc = RespawnDisclaimed(argv);
        if (rc >= 0)
            return rc;
    }
    @autoreleasepool
    {
        return Run(argc, argv);
    }
}
