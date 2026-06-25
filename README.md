# Balatro Mobile Lovely Injector (MLI)
This is a specially made Lovely injector for the PC to APK repackage tool for Balatro made by blake502. This allows you to play Balatro mods on the go!
# What This Does
1. Inserts Lovely code directly into the apk so that it runs at launch.
2. Gives Balatro the ability to read mod info from a dedicated "Mods" folder in your mobile device's downloads. No need to root your phone to gain access to the com.balatro data folders that are protected under android security!
3. Writes MLI reports and game dumps in case you run into errors directly to your device's downloads.
4. Provides a little pop-up once SMODS has been patched detailing what has worked (or what hasn't).
# Disclaimers!
This is for Android only! Sorry Apple users. I truly have no idea how to pick apart IOS apps. Also, for Pixel users, I tried my methods on a Google Pixel and encountered an issue with limited storage access. Something about Pixel phones handle storage security is different than other Android devices. I still haven't found a workaround for this yet so I apologize.

I have not tested full mod compatibility and most new mods reveal issues with my MLI system via crashing the game. The mods I have tested and know, as far as I'm aware, work are Steamodded, Pokermon, Multiplayer, and Cryptid (and by extension Amulet). There are some caveats but I will go over those at the end. I will of course, work on more mod compatibility as time goes on, but I figured the best way to know what people would want is to put this out here for others.

These instructions require that you create a new APK from an UNMODDED version of Balatro without any save data transferred over. We will be adding all the necessary mods during this process. You should be able to do this without removing all the mods from your modded PC experience by opting to not transfer save data during the repack, but if you encounter any issues, I'd recommend starting from the beginning and removing mods from PC. I can't guarantee any save data from an existing mobile Balatro repack will survive this process. So if you really want to keep your save data, I recommend changing this version's name (which I'll go over at the end). 

THIS IS NOT A FREE APK! This whole process starts with you having your own legally purchased copy of Balatro and converting it into an APK yourself!

Finally, for complete transparency, I made this using Anthropic's Claude coding. THIS IS NOT AN ADVERTISEMENT! I just felt that I needed to be honest about something like this. There are so many incredibly intelligent and talented content creators and coders for this game. I am not one of them and I will not disrespect them by pretending to be one. That being said, this is designed to work with their mods AS IS. I would never dare to insult them by altering their hard work. I just wanted to create sometehing that allowed me to enjoy their work to the fullest. Hopefully this will help you achieve the same.
# Requirements
1. Please read this top to bottom and follow the instructions carefully!
2. A repackaged version of PC Balatro as an APK. This can be done by using blake502's Balatro Mobile Maker found here. https://github.com/blake502/balatro-mobile-maker
3. Some way of decompiling and recompiling an APK. I was able to do all of this right from my mobile devices by using Apktool M! https://maximoff.su/apktool/?lang=en (Recommended because I didn't try other tools.)
4. Steamodded version 1.0.0-BETA-1814a. https://github.com/Steamodded
5. Mobile Lovely Injector (MLI).
6. SmodsColourGuard from the mods starter kit.
# Getting Started
These instructions assume you have already created your APK of Balatro. If you have not, please do so from the requirements above and come back!
1. Decompile your apk using your preferred tool. Again, I seriously recommend Apktool M. It's the tool I used and allowed me to do this pretty easily from my phone. (I honestly don't know how similar other APK tools are to one another, so I apologize if these instruction are not ubiquitous).
2. Once your game has been decompiled, you are looking for two things: "AndroidManifest.xml and "game.love". game.love will be located inside the assets folder.
# Android Manifest
This is pretty straight forward. All you need to do is add one new permission that allows the game to read and write into your storage like I mentioned in "What This Does". 
uses-permission android:name="android.permission.MANAGE_EXTERNAL_STORAGE"/ (Removed <> at beginning and end respectively so that the actual line still appears here on the github page, but they are required).
That's it for the manifest!
# game.love
1. Convert your "game.love" into "game.zip". This doesn't require any tools. It's as simple as renaming the .love portion to .zip.
2. Extract your game.zip. I recommend extracting it to "game" or any other dedicated folder to avoid confusion with what's already in assets.
3. In the extracted zip, locate main.lua and rename it to main_original.lua.
4. Download the MLI Kit and extract it to a dedicated folder if you haven't already. Copy the contents "main.lua" and the "mli" folder and place them directly into the game's root folder.
5. Take "main_original.lua" and put it into the mli folder.
6. Compress everything in the root folder and name it "game.love". If the option for compression level is available (Apktool M), I'd recommend setting that to 0.
7. Take the game.love and move it up one folder back into assets.
*Be careful not to nest the game within itself! I've made the mistake plenty of times where my directory looks like game/game/everything else and wondered why it wasn't working. It should always be game/everything else!*
8. You are now free to delete the game.zip and game directory from assets.
8.5 If you need to rename this version of Balatro to protect the save data of an already existing Balatro repack, this is the time to skip to "Protecting Save Data and Changing the Game's Name"
9. Compile the project and install the game!
You are more than welcome to run the game as is. Just to make sure the game actually boots vanilla. You'll probably see a pop-up that mentions giving all files access to the game. That's detailed in the next segment.
# Give Balatro All Files Access
This can be done by going to your settings and searching "All files access". If you do not see Balatro as an option to grant permission, it means that you forgot to change your Android Manifest. Please go back to that section and confirm you have uses-permission android:name="android.permission.MANAGE_EXTERNAL_STORAGE"/ added (including the > at the very end and < at the very beginning).

I promise that I'm not doing anything shady despite how intimidating all files access sounds! This was my way of allowing people to manually add and remove mods without needing to use the repack tool every time or root their phones!
# Mods
Almost there!
1. In your device's storage, go to downloads and create a folder named "Mods". This is case sensitive! "mods" will not work!
2. Insert the mods you wish to play with (steamodded required as well as SmodsColourGuard from the mods starter kit). Currently, Cryptid (requires Amulet which is working as well), Pokermon, Multiplayer, and some of my own personal mods that make the game work under certain conditions (also in the starter kit). I extracted every mod's .zip and placed the contents in Mods. For instance: Mods/Steamodded/Steamodded's content. *be careful not to nest the mods within themselves!*
3. While it may not be required on your device, I highly recommend keeping AtlasMemFix and the LowResTextures mods in your back pocket for later.
4. With the mods installed and all files access granted, you should be ready to restart the game (always fully close the game before trying to return).

The intial boot sequence after a new installation/update and changing the mod folder's content always results in a long boot time (sometimes upwards of 5 minutes in my experience). This is totally normal. As the phone is trying to patch everything together and create a cache. Each subsequent boot has a significantly faster boot time. Pretty much immediate. Even with all the mods installed.

If you are experiencing an issue where you stare at a black screen for a while and it suddenly force closes, please use the mentioned Atlas and LowRes mods. Your device cannot handle the memory demands that the initial boot requires. For reference, I did this on my Galaxy S22 Ultra and Galaxy Tab S10. The mods are created to lighten the burden and make sure the game can actually complete that initial boot on my phone. My tablet did not require the memory mods, but they never hurt to have anyways. You can use each mod individually, but I find that they work best together. I know lowres sounds less than ideal, but I promise that on a mobile device, there is barely any noticeable change. If you notice one at all.

If your game boots to the main menu, CONGRATS! You are now finished and free to enjoy your modded Balatro Experience on the go!
# What My Mods Do from the Starter Kit Do
Here's a quick breakdown of what my mods do. Again SmodsColourGuard is required!

1. SmodsColourGuard REQUIRED. Prevents a rare Steamodded tooltip crash (guards a nil-colour lookup in SMODS.localize_box).
2. AtlasMemFix RECOMMENDED. Frees the redundant CPU copy of each atlas after its GPU texture is built. Lowers memory, no visual change. Safe to keep installed everywhere.
3. LowResTextures OPTIONAL (low-RAM phones). Forces 1x textures to cut texture memory ~4x. Trade-off: lower-res sprites. Try AtlasMemFix alone first; add this only if the game still force-closes on the long first boot.
4. HelloMod OPTIONAL. A tiny example/signature mod and a template for writing your own MLI-compatible mods (if that's something that would interest you).

NOTE: AtlasMemFix and SmodsColourGuard patch Steamodded's own source by exact
lines, so they are matched to the Steamodded version MLI was tested against.
Use that version; a newer Steamodded may silently stop these from applying.
# Protecting Save Data and Changing the Game's Name
If you already have an apk repack and wish to prevent that data from being overwritten, all you need to do is change a couple things in the AndroidManifest.xml!
1. Locate "<Manifest" (Should be right on top) and change the package name from: package="com.unofficial.balatro" to something like package="com.unofficial.balatro.mli". This will change where your new Balatro writes its save data.
Technically, you're all set! The new Balatro will save somewhere else! If you'd like to change the name of the game so that it's visually distinct from your other copy, follow step 2.
2. Inside AndroidManifest.xml, under "<application" and "<activity" change the two instances of "Balatro" to whatever you want! So long as they are the same. As an example, you could change both to "Balatro MLI".

You're all set!
# Some Caveats
Being that I have used the most recent version of SMODS, there are some specific features of certain mods that don't work as intended. I have a small list here from my own personal testing. I'm sure the list will get bigger as more people play. None of these crash the game and the mods are otherwise fully content compatible.

Cryptid: 
The boss blind, "The Tax", does not implement its hand score limit. It can be done in one hand.
Giving a card the Global effect via the Code consumable does not function. The card gets the tag, but doesn't draw itself first at the beginning of blinds.

Multiplayer:
Standard Ranked and Legacy Ranked are not playable. This is simply because I am using SMODS version 1.0.0-BETA-1814a and not 1.0.0-BETA-1620a.

All mods:
Any mod with a config option that requires a restart (including disabling the mod entirely) does not work. If you want to disable a mod, it's best to just remove it from your mods folder. This will require a long reboot once again.

I have not tested every possible interaction myself. I am only one person. So please don't be afraid to report any issues that you may encounter during your play!

Finally, I recommend running the game with only SMODS and Colourguard installed in the Mods folder first. Just to make sure that the actual SMmods framework is running as intended. You could always go all in at once, but if something goes wrong, start from those two mods and add others one at a time.
# Shoutouts
I just wanted to take a moment here at the end and give a shoutout to all the people who make modded Balatro and Balatro mobile possible. They are all incredibly talented individuals who created things for the community I could have never dreamed up. Especially to those who created Lovely, Steamodded, and the Balatro Mobile Maker. None of what I did would be possible without them giving me a foundation to work from. It's only thanks to their hard work and the work of all the creators out there that I could even create something like this for you all. I hope you all enjoy! 
