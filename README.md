# Balatro Mobile Lovely Injector (MLI)
This is a specially made Lovely injector for the PC to APK repackage of Balatro made by blake502. This allows you to play Balatro mods on the go!
# What This Does
1. Inserts Lovely code directly into the apk so that it runs at launch.
2. Gives Balatro the ability to read mod info from a dedicated "Mods" folder in your mobile device's downloads. No need to root your phone to gain access to the com.balatro data folders that are protected under android security!
3. Writes mli reports and game dumps in case you run into errors directly to your device's downloads.
# Disclaimers!
This is for Android only! Sorry Apple users. I truly have no idea how to pick apart IOS apps. Also, for Pixel users, I tried my methods on a Google Pixel and ecountered an issue with limited storage access. Something about Pixel's do storage security differently than other Android devices. I still haven't found a workaround for this yet so I apologize.

I have not tested full mod compatability and most new mods reveal a issues with my MLI system via crashing the game. The mods I have tested and know, as far as I'm aware, work are Pokermon, Multiplayer, and Crpytid (and by extension Amulet). I of course will work on more mod compatability as time goes on, but I figured the best way to know what people would want is to put this out here for others.

THIS IS NOT A FREE APK! This whole process starts with you having your own legally purchased copy of Balatro and converting it into an APK yourself!

Finally, I made this using Anthropic's Claude coding. THIS IS NOT AN ADVERTISEMENT! I just felt that I needed to be honest about something like this. There are so many incredibly intelligent and talent content creator's and coders for this game. I am not one of them. That being said, this is designed to work with their mods AS IS. I would never dare to alter their hard work. I just wanted to create sometehing that allowed me to enjoy their work to the fullest. Hopefully this will help you achieve the same goal as well.
# Requirements
1. A repackaged version of PC Balatro as an APK. This can be done by using blake502's Balatro Mobile Maker found here. https://github.com/blake502/balatro-mobile-maker
2. Some way of decompiling and recompiling an APK. I was able to do all of this right from my mobile devices by using Apktool M! https://maximoff.su/apktool/?lang=en (Recommended because I didn't try other tools.)
3. The latest version of Steamodded (at the time of writing this, that is version 1.0.0-BETA-1814a). https://github.com/Steamodded
# Getting Started
These instructions assume you have already created your APK of Balatro. If you have not, please do so from the requirements above and come back!
1. Decompile your apk using your preferred tool. Again, I seriously recommend Apktool M. It's the tool I used and allowed me to do this pretty easily from my phone. (I honestly don't know how similar other APK tools are to one another, so I apologize if these instruction are not ubiquitous).
2. Once your game has been decompiled, you are looking for two things: "AndroidManifest.xml and "game.love". game.love will be located inside the assests folder.
# Android Manifest
This is pretty straight forward. All you need to do is add this permission line right after the others.
<uses-permission android:name="android.permission.MANAGE_EXTERNAL_STORAGE"/>
This is what allows the game to be able to read and write inside your downloads folder. Skipping the need for rooting your device.
