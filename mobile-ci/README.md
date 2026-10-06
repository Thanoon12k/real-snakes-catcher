# Mobile build preparation

The app currently has an Android runner. The workflow builds the existing Flutter app for Android and generates an iOS runner on a macOS runner for an **unsigned compile check**. A successful compilation is not a completed iOS release; camera behavior, saving videos, notifications and foreground monitoring must still be tested on real iPhones.

## Android

`Android APK and iOS build check` builds `app-release.apk` and uploads it as a GitHub Actions artifact. The existing Android build uses debug/test signing. Downloading Actions artifacts may require GitHub sign-in. To distribute a permanent production APK, configure a release keystore using repository secrets, test the app, and attach the signed APK to a GitHub Release. Do not claim a public APK exists until that release asset exists. Keep the same signing key for updates.

## iPhone

The workflow output `Runner.app` is unsigned and **cannot be installed on an ordinary iPhone**. To create a distributable app:

1. Open/generated iOS project on a Mac with Xcode and select the correct Apple developer team and a unique bundle identifier.
2. Review camera, microphone, gallery permissions and minimum supported iOS version. The helper adds usage descriptions and permission_handler CocoaPods definitions where a Podfile is present.
3. Test the app on physical iPhones, especially camera capture while recording, gallery saving, Telegram polling and keeping the app in the foreground. Android and iOS behavior may differ.
4. Configure signing/provisioning; archive and distribute using TestFlight or App Store Connect with the owner's Apple developer account.
5. Replace the iPhone page's status with the verified TestFlight/App Store URL only after publication.

Do not enter signing credentials or bot tokens on the marketing website.

## Website QR codes

The two QR codes open stable, public platform pages on the website. They currently describe availability and link to the source/releases. They **are not direct app download codes**. After real artifacts are available, update the platform pages with verified APK and TestFlight/App Store links. The printed codes can remain unchanged.
