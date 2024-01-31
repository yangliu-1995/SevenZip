//
//  SVZArchive.m
//  SevenZip
//
//  Created by Tamas Lustyik on 2015. 11. 19..
//  Copyright © 2015. Tamas Lustyik. All rights reserved.
//

#import "SVZArchive.h"
#import "SVZArchive_Private.h"

#include "CPP/7zip/IDecl.h"
#include "CPP/Windows/PropVariant.h"
#include "CPP/Windows/PropVariantConv.h"
#include "CPP/Windows/TimeUtils.h"
#include "CPP/Common/UTFConvert.h"

#include "SVZArchiveOpenCallback.h"
#include "SVZArchiveUpdateCallback.h"
#include "SVZInFileStream.h"
#include "SVZOutFileStream.h"

#import "SVZArchiveEntry_Private.h"
#import "SVZBridgedInputStream.h"
#import "SVZStoredArchiveEntry.h"
#import "SVZUtils.h"

int g_CodePage = -1;

NSString* const kSVZArchiveErrorDomain = @"SVZArchiveErrorDomain";

#define INITGUID
#include "MyGuidDef.h"
// {23170F69-40C1-278A-1000-000110010000}
DEFINE_GUID(CLSIDFormatZip, 0x23170F69, 0x40C1, 0x278A, 0x10, 0x00, 0x00, 0x01, 0x10, 0x01, 0x00, 0x00);

// {23170F69-40C1-278A-1000-000110070000}
DEFINE_GUID(CLSIDFormat7z, 0x23170F69, 0x40C1, 0x278A, 0x10, 0x00, 0x00, 0x01, 0x10, 0x07, 0x00, 0x00);

// {23170F69-40C1-278A-1000-000110EE0000}
DEFINE_GUID(CLSIDFormatTar, 0x23170F69, 0x40C1, 0x278A, 0x10, 0x00, 0x00, 0x01, 0x10, 0xEE, 0x00, 0x00);

#undef INITGUID

STDAPI CreateArchiver(const GUID *clsid, const GUID *iid, void **outObject);


static void SetError(NSError** aError, SVZArchiveError aCode, NSDictionary* userInfo) {
    if (!aError) {
        return;
    }

    *aError = [NSError errorWithDomain:kSVZArchiveErrorDomain
                                  code:aCode
                              userInfo:userInfo];
}


@interface SVZArchive ()

@property (nonatomic, strong, readonly) NSFileManager* fileManager;

@property (nonatomic, assign, readonly) SVZArchiveFormat format;

@end


@implementation SVZArchive

+ (SVZ_NULLABLE instancetype)archiveWithURL:(NSURL*)aURL
                            createIfMissing:(BOOL)aShouldCreate
                                      error:(NSError**)aError {
    return [[self alloc] initWithURL:aURL
                            password:nil
                     createIfMissing:aShouldCreate
                               error:aError];
}

+ (SVZ_NULLABLE instancetype)archiveWithURL:(NSURL*)aURL
                              archiveFormat:(SVZArchiveFormat)aFormat
                            createIfMissing:(BOOL)aShouldCreate
                                      error:(NSError**)aError {
    return [[self alloc] initWithURL:aURL
                       archiveFormat:aFormat
                            password:nil
                     createIfMissing:aShouldCreate
                               error:aError];
}

+ (SVZ_NULLABLE instancetype)archiveWithURL:(NSURL*)aURL
                              archiveFormat:(SVZArchiveFormat)aFormat
                                   password:(NSString* SVZ_NULLABLE_PTR)aPassword
                                      error:(NSError**)aError {
    return [[self alloc] initWithURL:aURL
                       archiveFormat:aFormat
                            password:aPassword
                     createIfMissing:NO
                               error:aError];
}

+ (SVZ_NULLABLE instancetype)archiveWithURL:(NSURL*)aURL
                                   password:(NSString*)aPassword
                                      error:(NSError**)aError {
    return [[self alloc] initWithURL:aURL
                            password:aPassword
                     createIfMissing:NO
                               error:aError];
}

- (SVZ_NULLABLE instancetype)initWithURL:(NSURL*)aURL
                                password:(NSString*)aPassword
                         createIfMissing:(BOOL)aShouldCreate
                                   error:(NSError**)aError {
    return [self initWithURL:aURL
               archiveFormat:kSVZArchiveFormat7z
                    password:aPassword
             createIfMissing:aShouldCreate
                       error:aError];
}

- (SVZ_NULLABLE instancetype)initWithURL:(NSURL*)aURL
                           archiveFormat:(SVZArchiveFormat)aFormat
                                password:(NSString*)aPassword
                         createIfMissing:(BOOL)aShouldCreate
                                   error:(NSError**)aError {
    NSParameterAssert(aURL);
    NSAssert([aURL isFileURL], @"url must point to a local file");

    self = [super init];
    if (self) {
        _url = aURL;
        _fileManager = [[self class] fileManager];
        _entries = @[];
        _format = aFormat;

        BOOL isDir = NO;
        if ([self.fileManager fileExistsAtPath:aURL.path isDirectory:&isDir]) {
            // opening existing archive
            if (isDir) {
                SetError(aError, kSVZArchiveErrorInvalidArchive, nil);
                self = nil;
            }
            else if (![self readEntriesWithPassword:aPassword error:aError]) {
                self = nil;
            }
        } else {
            // archive doesn't exist yet
            if (!aShouldCreate) {
                // and this is an error
                SetError(aError, kSVZArchiveErrorFileNotFound, nil);
                self = nil;
            }
        }
    }
    return self;
}

- (void)dealloc {
    _archive = nullptr;
}

- (BOOL)updateEntries:(SVZ_GENERIC(NSArray, SVZArchiveEntry*)*)aEntries
                error:(NSError**)aError {
    return [self updateEntries:aEntries
                  withPassword:nil
              headerEncryption:NO
              compressionLevel:kSVZCompressionLevelNormal
                         error:aError];
}

- (BOOL)updateEntries:(SVZ_GENERIC(NSArray, SVZArchiveEntry*)*)aEntries
         withPassword:(NSString*)aPassword
     headerEncryption:(BOOL)aEnableHeaderEncryption
     compressionLevel:(SVZCompressionLevel)aCompressionLevel
                error:(NSError**)aError {
    if (!aPassword) {
        aEnableHeaderEncryption = NO;
    }

    CObjectVector<SVZ::ArchiveItem> archiveItems;
    SVZ_GENERIC(NSMutableArray, SVZStoredArchiveEntry*)* storedEntries = [NSMutableArray arrayWithCapacity:aEntries.count];

    int index = 0;
    for (SVZArchiveEntry* entry in aEntries) {
        SVZ::ArchiveItem item;

        if ([entry isKindOfClass:[SVZStoredArchiveEntry class]]) {
            SVZStoredArchiveEntry* storedEntry = (SVZStoredArchiveEntry*)entry;
            SVZArchive* hostArchive = storedEntry.archive;

            if (!hostArchive || hostArchive.archive != self.archive) {
                // foreign entries are not supported
                SetError(aError, kSVZArchiveErrorForeignEntry, @{@"entry": entry});
                return NO;
            }

            item.currentIndex = (Int32)storedEntry.index;
            [storedEntries addObject:storedEntry];
        } else {
            item.currentIndex = SVZ::ArchiveItem::kNewItemIndex;
        }

        item.id = index++;
        item.attrib = entry.attributes;
        item.size = entry.uncompressedSize;
        item.name = ToUString(entry.name);
        item.isDir = entry.isDirectory;

        NWindows::NTime::UnixTimeToFileTime([entry.creationDate timeIntervalSince1970], item.cTime);
        NWindows::NTime::UnixTimeToFileTime([entry.modificationDate timeIntervalSince1970], item.mTime);
        NWindows::NTime::UnixTimeToFileTime([entry.accessDate timeIntervalSince1970], item.aTime);

        archiveItems.Add(item);
    }

    SVZ::OutFileStream* outFileStreamImpl = new SVZ::OutFileStream();
    CMyComPtr<IOutStream> outputStream = outFileStreamImpl;
    if (!outFileStreamImpl->Open(self.url.path.UTF8String)) {
        SetError(aError, kSVZArchiveErrorFileOpenFailed, nil);
        return NO;
    }

    CMyComPtr<IOutArchive> outArchive;
    HRESULT result;

    if (storedEntries.count > 0) {
        result = self.archive->QueryInterface(IID_IOutArchive, (void**)&outArchive);
        NSAssert(result == S_OK, @"archiver object does not support updates");
    }

    if (!outArchive) {
        const GUID *clsid = nil;
        switch (self.format) {
            case kSVZArchiveFormatZip:
                clsid = &CLSIDFormatZip;
                break;
            case kSVZArchiveFormat7z:
                clsid = &CLSIDFormat7z;
                break;
            case kSVZArchiveFormatTar:
                clsid = &CLSIDFormatTar;
                break;
            default:
                NSAssert(0, @"Unknown Archive Format");
        }
        result = CreateArchiver(clsid, &IID_IOutArchive, (void**)&outArchive);
        NSAssert(result == S_OK, @"cannot instantiate archiver");
    }

    // update properties
    CMyComPtr<ISetProperties> setProperties;
    result = outArchive->QueryInterface(IID_ISetProperties, (void**)&setProperties);
    NSAssert(result == S_OK, @"archiver object does not support setting properties");

    const UInt32 kRawLevelValue[] = {
        [kSVZCompressionLevelNone] = 0,
        [kSVZCompressionLevelLowest] = 1,
        [kSVZCompressionLevelLow] = 3,
        [kSVZCompressionLevelNormal] = 5,
        [kSVZCompressionLevelHigh] = 7,
        [kSVZCompressionLevelHighest] = 9,
    };

    const wchar_t* names[] = { L"he", L"x" };
    const unsigned kNumProps = ARRAY_SIZE(names);
    NWindows::NCOM::CPropVariant values[kNumProps] = {
        aPassword && aEnableHeaderEncryption ? L"on" : L"off",
        kRawLevelValue[aCompressionLevel]
    };
    setProperties->SetProperties(names, values, kNumProps);

    // update entries
    SVZ::ArchiveUpdateCallback* updateCallbackImpl = new SVZ::ArchiveUpdateCallback();
    CMyComPtr<IArchiveUpdateCallback2> updateCallback(updateCallbackImpl);
    if (aPassword) {
        updateCallbackImpl->passwordIsDefined = true;
        updateCallbackImpl->password = ToUString(aPassword);
    }

    updateCallbackImpl->Init(&archiveItems, [&] (Int32 itemID) -> CMyComPtr<ISequentialInStream> {
        @autoreleasepool {
            SVZArchiveEntry* entry = aEntries[itemID];
            CMyComPtr<ISequentialInStream> inStream = new SVZ::BridgedInputStream(entry.dataStream);
            return inStream;
        }
    });

    result = outArchive->UpdateItems(outputStream, archiveItems.Size(), updateCallback);

    updateCallbackImpl->Finalize();

    if (result != S_OK || updateCallbackImpl->FailedFiles().Size() != 0) {
        SetError(aError, kSVZArchiveErrorUpdateFailed, nil);
        return NO;
    }

    // explicit close is required to flush the stream to disk before reading it back
    outFileStreamImpl->Close();

    [storedEntries makeObjectsPerformSelector:@selector(invalidate)];

    return [self readEntriesWithPassword:aPassword error:aError];
}

#pragma mark - private methods:

- (BOOL)readEntriesWithPassword:(NSString*)aPassword error:(NSError**)aError {
    if (![self openArchiveWithPassword:aPassword error:aError]) {
        return NO;
    }

    UInt32 numItems = 0;
    self.archive->GetNumberOfItems(&numItems);
    SVZ_GENERIC(NSMutableArray, SVZArchiveEntry*)* storedEntries = [NSMutableArray arrayWithCapacity:numItems];

    for (UInt32 i = 0; i < numItems; i++) {
        SVZStoredArchiveEntry* entry = [[SVZStoredArchiveEntry alloc] initWithIndex:i inArchive:self];
        [storedEntries addObject:entry];
    }

    _entries = [storedEntries copy];

    return YES;
}

- (BOOL)openArchiveWithPassword:(NSString*)aPassword error:(NSError**)aError {
    CMyComPtr<IInArchive> archive;
    const GUID *clsid = nil;
    switch (self.format) {
        case kSVZArchiveFormatZip:
            clsid = &CLSIDFormatZip;
            break;
        case kSVZArchiveFormat7z:
            clsid = &CLSIDFormat7z;
            break;
        case kSVZArchiveFormatTar:
            clsid = &CLSIDFormatTar;
            break;
        default:
            NSAssert(0, @"Unknown Archive Format");
    }
    HRESULT result = CreateArchiver(clsid, &IID_IInArchive, (void **)&archive);
    NSAssert(result == S_OK, @"cannot instantiate archiver");

    SVZ::InFileStream* inFileStreamImpl = new SVZ::InFileStream();
    CMyComPtr<IInStream> inputStream(inFileStreamImpl);

    if (!inFileStreamImpl->Open(self.url.path.UTF8String)) {
        SetError(aError, kSVZArchiveErrorFileOpenFailed, nil);
        return NO;
    }

    SVZ::ArchiveOpenCallback* openCallbackImpl = new SVZ::ArchiveOpenCallback();
    CMyComPtr<IArchiveOpenCallback> openCallback(openCallbackImpl);
    if (aPassword) {
        openCallbackImpl->passwordIsDefined = true;
        openCallbackImpl->password = ToUString(aPassword);
    }

    if (archive->Open(inputStream, nullptr, openCallback) != S_OK) {
        SetError(aError, kSVZArchiveErrorInvalidArchive, nil);
        return NO;
    }

    self.archive = archive;
    return YES;
}

#pragma mark - UT helpers:

+ (NSFileManager*)fileManager {
    return [NSFileManager defaultManager];
}

@end
