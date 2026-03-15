# BetterReader

A small macOS utility that fixes a common problem with Text-to-Speech when reading PDFs.

Many PDFs insert a newline at the end of every visual line. macOS Text-to-Speech interprets these line breaks as pauses, causing speech to stop at the end of each line and making listening difficult.

BetterReader acts as a **thin layer between selected text and macOS Text-to-Speech**, removing unnecessary newline characters before the text is spoken so sentences flow naturally.

## Icon

Put the source icon image at `icon.png` in the repository root. Use a square 1024x1024 PNG.

- GitHub uses that same `icon.png` directly from the README.
- The macOS app icon is generated from it by running `scripts/sync_icon.sh`.

## Usage

1. Select text in any application (PDF reader, browser, editor, etc.).
2. Press **Option + P** to start reading.
3. Press **Option + O** to stop.

## Setup
Option 1: Download the **BetterReader.app.zip** file, unzip and move to your Applications folder.  
Option 2: Download the project and build the binary yourself. Move the it to your Applications folder.  

Then you may need to configure a few things in macOS settings:

- **Trust the app:** if macOS warns that it is from an unidentified developer. The exact procedure varies a bit depending on the macOS version. For Tahoe 26.3:  
  Allow it in *System Settings → Privacy & Security → Allow apps from: App Store & Known Developers*.  
  Then add me to the list of trusted developers.   
- **Enable Accessibility permission** so the app can read selected text.  
  *System Settings → Privacy & Security → Accessibility*
- *(Optional)* Select a **high-quality Siri voice** for better speech.  
  *System Settings → Accessibility → Spoken Content → System Voice*
- *(Optional)* Add the app to **Login Items** if you want it to run automatically at startup.  
  *System Settings → General → Login Items → Open at Login*

## License

This project is **fully open source**. You are free to use, modify, distribute, or incorporate the code into other projects without restriction.
