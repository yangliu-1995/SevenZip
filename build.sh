rm -rf build
xcodebuild archive -project SevenZip.xcodeproj -scheme "SevenZip (iOS)" -destination "generic/platform=iOS" -archivePath "build/archives/SevenZip-iOS" SKIP_INSTALL=NO BUILD_LIBRARY_FOR_DISTRIBUTION=YES
xcodebuild archive -project SevenZip.xcodeproj -scheme "SevenZip (iOS)" -destination "generic/platform=iOS Simulator" -archivePath "build/archives/SevenZip-iOS_Simulator" SKIP_INSTALL=NO BUILD_LIBRARY_FOR_DISTRIBUTION=YES
xcodebuild -create-xcframework -archive "build/archives/SevenZip-iOS.xcarchive" -framework SevenZip.framework -archive "build/archives/SevenZip-iOS_Simulator.xcarchive" -framework SevenZip.framework -output "build/xcframeworks/SevenZip.xcframework"