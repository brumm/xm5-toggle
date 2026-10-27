# xm5-toggle

Tiny macOS CLI to control noise cancelling on Sony WH-1000XM5 headphones over Bluetooth. Built on [libmdr](https://github.com/mos9527/SonyHeadphonesClient) (vendored in `src/`).

```
xm5 status            print noise mode, ambient level, playback status
xm5 nc                noise cancelling
xm5 ambient [0-20]    ambient sound (default 20)
xm5 off               noise control off
xm5 toggle            NC -> pause + ambient; ambient/off -> NC + resume (if it was playing)
```

Environment:

- `XM5_ADDR=AA:BB:...` pick a device by MAC (default: first paired device whose name contains "1000XM")
- `XM5_DEBUG=1` verbose logging

## Build

Requires macOS, CMake 3.31+ and Ninja.

```sh
cmake -S xm5 -B xm5/build -G Ninja
cmake --build xm5/build
./xm5/build/xm5 status
```

The first run triggers a macOS Bluetooth permission prompt.

## Credits

`src/` is a copy of [mos9527/SonyHeadphonesClient](https://github.com/mos9527/SonyHeadphonesClient) (MIT, see `src/LICENSE`).
