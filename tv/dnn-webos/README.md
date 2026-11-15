# DNN for LG webOS TVs

A thin launcher: the app opens the DNN page that `supervisor/dnn.py` serves on the
stream machine (`http://192.168.1.18:8769/` — change `URL` in `app/index.html` if the
stream machine moves). The TV must be on the same network.

Remote: OK or Right = skip to the next line, Left = replay the line, Down = sound on/off, Back = exit.

Build and install (Developer Mode TV paired as `lgtv`):

    ares-package tv/dnn-webos/app -o tv/dnn-webos/build
    ares-install -d lgtv tv/dnn-webos/build/tv.dnn.dwarfnews_1.0.0_all.ipk
    ares-launch -d lgtv tv.dnn.dwarfnews

The same page works as an OBS Browser Source: `http://localhost:8769/?obs=1` at
1920x1080 (the live-video box is transparent; put Game Capture under it at
x=40 y=110, 1216x684).
