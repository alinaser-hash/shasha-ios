# libmpv patches

`0099-avfoundation-video-output.patch` adds mpv's `avfoundation` video output (draws into an
`AVSampleBufferDisplayLayer`, which iOS picture in picture needs). Taken unchanged from Streamyfin's
MPVKit fork, tag `0.41.0-av5` (https://github.com/streamyfin/MPVKit), file
`Sources/BuildScripts/patch/libmpv/0004-avfoundation-video-output.patch`, author Alex Kim.
The new file `video/out/vo_avfoundation.m` is under the GNU LGPL 2.1 or later, like mpv's LGPL build.

`scripts/build-libmpv.sh` applies it on top of MPVKit's own patches and builds libmpv only.
