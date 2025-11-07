<p align="center">
  <img width="256" alt="header image with app icon" src="./LosslessMusic/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x-512.png">

</p>

#  

LosslessMusic switches your current audio device's sample rate to match the currently playing lossless music on your Apple Music app, automatically.

Let's say if the next song that you are playing, is a Hi-Res Lossless track with a sample rate of 192kHz, LosslessMusic will switch your device to that sample rate as soon as possible. 

The opposite happens, when the next track happens to have a lower sample rate. 


## Installation
Drag the app to your Applications folder. If you wish to have it running when logging in, you should be able to add LosslessMusic in System Settings:

```
> User & Groups > Login Items > Add LosslessMusic app
```

## App details

There isn't much going on, when it comes to the UI of the app, as most of the logic is to:
1. Read Apple Music's logs to know the song's sample rate.
2. Read Apple Music's logs to know when the track is changed (New in MacOS 26)
3. Combine the above information to set the sample rate to the device that you are currently playing to.

As such, the app lives on your menu bar. The screenshot above shows it's only UI component that it offers, which is to show the sample rate that it has parsed from Apple Music's logs.

<img width="252" alt="app screenshot, with music note icon shown as UI button" src="https://user-images.githubusercontent.com/23420208/164895657-35a6d8a3-7e85-4c7c-bcba-9d03bfd88b4d.png">


Do also note that:
- There may be short interuptions to your audio playback, during the time where the app attempts to switch the sample rates.
- Prolonged use on MacBooks may accelerate battery usages, due to the frequent querying of the latest sample rate.
- Apple Music on MacOS 26 now logs the current playing track, so this makes this app much more easy to precisly swith the sample rate. And because of this, This app only works on MacOS 26 and later.

Bit Depth switching is also supported, although, not every DAC fullly support 16/24/32 bit depth, but no worry, if you DAC don't support 16 bits, it will switch to use 24 bits, and it's also bit-perfect.


### Why make this?
Ever since Apple Music Lossless launched along with macOS 11.4, the app would never switch the sample rates according to the song that was playing. A trip down to the Audio MIDI Setup app was required.
This still happens today, with macOS 12.3.1, despite iOS's Music app having such an ability.

I think this improvement might be well appreciated by many, hence this project is here, free and open source.

## Prerequisites
Because this app requires to read the system log, and I don’t want to use the pull-query mode, so I use `log stream` which make this app can not be sandboxed.


## Caveats
There is a small catch: because there is no direct way of getting the current playing music’s sample rate info without using the private api, which might change between the OS version. So I have to use some trick to determine the sample rate for current playing track. And streaming music use a lot of caching, these caching might contain different information about the sample rate. So, if you shuffle one track a lot just right at next track’s info is captured and current tracks new info comes later, then the next track’s info will be lost. 

But, is there anyone listen the music by shuffle one track many times, right?

## Disclaimer
By using LosslessMusic, you agree that under no circumstances will the developer or any contributors be held responsible or liable in any way for any claims, damages, losses, expenses, costs or liabilities whatsoever or any other consequences suffered by you or incurred by you directly or indirectly in connection with any form of usages of LosslessMusic.

## License
LosslessMusic is licensed under GPL-3.0.

## Credits
This project is inspired by [vincentneo/LosslessSwitcher](https://github.com/vincentneo/LosslessSwitcher), Which uses AppleScript to monitor the Apple Music's logs, but I don't use AppleScript, just use `log watch`, I think this is much efficient way to monitor the sample rates and bit depth. Again, Thank you Vincent Neo!
