/**
 * @file GfxProviderCG.mm
 * @brief Graphics layer using Cocoa Touch
 *
 * (c) 2013-2015 by Mega Limited, Auckland, New Zealand
 *
 * This file is part of the MEGA SDK - Client Access Engine.
 *
 * Applications using the MEGA API must present a valid application key
 * and comply with the the rules set forth in the Terms of Service.
 *
 * The MEGA SDK is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 *
 * @copyright Simplified (2-clause) BSD License.
 *
 * You should have received a copy of the license along with this
 * program.
 */

#include "mega.h"
#include <MobileCoreServices/UTCoreTypes.h>
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIImage.h>
#import <MobileCoreServices/UTType.h>
#import <QuickLookThumbnailing/QuickLookThumbnailing.h>

const float COMP = 0.8f;
const int THUMBNAIL_MIN_SIZE = 200;

NSURL *sourceURL;

using namespace mega;

#ifndef USE_FREEIMAGE

GfxProviderCG::GfxProviderCG()
    : imageSource(NULL)
{
    w = h = 0;
    thumbnailParams = CFDictionaryCreateMutable(kCFAllocatorDefault, 3,
                                                &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionaryAddValue(thumbnailParams, kCGImageSourceCreateThumbnailWithTransform, kCFBooleanTrue);
    CFDictionaryAddValue(thumbnailParams, kCGImageSourceCreateThumbnailFromImageAlways, kCFBooleanTrue);

    CFNumberRef compression = CFNumberCreate(kCFAllocatorDefault, kCFNumberFloatType, &COMP);
    imageParams = CFDictionaryCreate(kCFAllocatorDefault, (const void **)&kCGImageDestinationLossyCompressionQuality, (const void **)&compression, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(compression);
    semaphore = dispatch_semaphore_create(0);
}

GfxProviderCG::~GfxProviderCG() {
    freebitmap();
    if (thumbnailParams) {
        CFRelease(thumbnailParams);
    }
    if (imageParams) {
        CFRelease(imageParams);
    }
}

const char* GfxProviderCG::supportedformats() {
    return ".bmp.cr2.crw.cur.dng.gif.heic.ico.j2c.jp2.jpf.jpeg.jpg.nef.orf.pbm.pdf.pgm.png.pnm.ppm.psd.raf.rw2.rwl.tga.tif.tiff.3g2.3gp.avi.m4v.mov.mp4.mqv.qt.webp.";
}

const char* GfxProviderCG::supportedvideoformats() {
    return NULL;
}

bool GfxProviderCG::readbitmap(FileSystemAccess* fa, const LocalPath& name, int size) {
    string absolutename;
    NSString *sourcePath;
    if (PosixFileSystemAccess::appbasepath && !name.beginsWithSeparator()) {
        absolutename = PosixFileSystemAccess::appbasepath;
        absolutename.append(name.platformEncoded());
        sourcePath = [NSString stringWithCString:absolutename.c_str() encoding:[NSString defaultCStringEncoding]];
    } else {
        sourcePath = [NSString stringWithCString:name.platformEncoded().c_str() encoding:[NSString defaultCStringEncoding]];
    }
    
    if (sourcePath == nil) {
        return false;
    }
    
    sourceURL = [NSURL fileURLWithPath:sourcePath isDirectory:NO];
    if (sourceURL == nil) {
        return false;
    }

    w = h = 0;

    CFStringRef fileExtension = (__bridge CFStringRef)[sourcePath pathExtension];
    CFStringRef fileUTI = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, fileExtension, NULL);
    if (UTTypeConformsTo(fileUTI, kUTTypeMovie)) {
        AVAsset *asset = [AVAsset assetWithURL:[NSURL fileURLWithPath:sourcePath]];
        AVAssetTrack *videoTrack = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
        CGSize naturalSize = videoTrack.naturalSize;
        w = naturalSize.width;
        h = naturalSize.height;
    } else {
        UIImage *image = [UIImage imageWithContentsOfFile:sourcePath];
        w = image.size.width;
        h = image.size.height;
    }

    if (fileUTI) {
        CFRelease(fileUTI);
    }

    if (!(w && h)) {
        w = h = size;
    }
    return w && h;
}

CGImageRef GfxProviderCG::createThumbnailWithMaxSize(int size) {
    CFNumberRef maxSize = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &size);
    CFDictionarySetValue(thumbnailParams, kCGImageSourceThumbnailMaxPixelSize, maxSize);
    CFRelease(maxSize);

    return CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbnailParams);
}

static inline CGRect tileRect(size_t w, size_t h)
{
    CGRect res;
    // square rw*rw crop thumbnail
    res.size.width = res.size.height = std::min(w, h);
    if (w < h)
    {
        res.origin.x = 0;
        res.origin.y = (h - w) / 2;
    }
    else
    {
        res.origin.x = (w - h) / 2;
        res.origin.y = 0;
    }
    return res;
}

int GfxProviderCG::maxSizeForThumbnail(const int rw, const int rh) {
    if (rh) { // rectangular rw*rh bounding box
        return std::max(rw, rh);
    }
    // square rw*rw crop thumbnail
    return ceil(rw * ((double)std::max(w, h) / (double)std::min(w, h)));
}

bool GfxProviderCG::resizebitmap(int rw, int rh, string* jpegout) {
    jpegout->clear();
    
    bool isThumbnail = !rh;
    
    if (isThumbnail) {
        if (w > h) {
            rh = THUMBNAIL_MIN_SIZE;
            rw = THUMBNAIL_MIN_SIZE * w / h;
        } else if (h > w) {
            rh = THUMBNAIL_MIN_SIZE * h / w;
            rw = THUMBNAIL_MIN_SIZE;
        } else {
            rw = rh = THUMBNAIL_MIN_SIZE;
        }
    }

    CGSize size = CGSizeMake(rw, rh);
    __block NSData *data;

    QLThumbnailGenerationRequest *request = [[QLThumbnailGenerationRequest alloc] initWithFileAtURL:sourceURL size:size scale:1.0 representationTypes:QLThumbnailGenerationRequestRepresentationTypeThumbnail];

    [QLThumbnailGenerator.sharedGenerator generateBestRepresentationForRequest:request completionHandler:^(QLThumbnailRepresentation * _Nullable thumbnail, NSError * _Nullable error) {
        if (error) {
            LOG_err << "Error generating best representation for a request: " << error.localizedDescription;
        } else {
            if (isThumbnail) {
                NSData *imageData = UIImageJPEGRepresentation(thumbnail.UIImage, COMP);
                
                imageSource = CGImageSourceCreateWithData((__bridge CFDataRef)imageData, NULL);
                
                CGImageRef image = createThumbnailWithMaxSize(maxSizeForThumbnail(THUMBNAIL_MIN_SIZE, 0));
                CGImageRef newImage = CGImageCreateWithImageInRect(image, tileRect(CGImageGetWidth(image), CGImageGetHeight(image)));
                if (image) {
                    CFRelease(image);
                }
                data = UIImageJPEGRepresentation([UIImage imageWithCGImage:newImage], 1);
                if (newImage) {
                    CFRelease(newImage);
                }
            } else {
                data = UIImageJPEGRepresentation(thumbnail.UIImage, COMP);
            }
        }
        dispatch_semaphore_signal(semaphore);
    }];
    
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    jpegout->assign((char*) data.bytes, data.length);
    return data;
}

void GfxProviderCG::freebitmap() {
    if (imageSource) {
        CFRelease(imageSource);
        imageSource = NULL;
    }
    w = h = 0;
}

#endif

void ios_statsid(std::string *statsid) {
    NSMutableDictionary *queryDictionary = [[NSMutableDictionary alloc] init];
    [queryDictionary setObject:(__bridge id)kSecClassGenericPassword forKey:(__bridge id)kSecClass];
    [queryDictionary setObject:@"statsid" forKey:(__bridge id)kSecAttrAccount];
    [queryDictionary setObject:@"MEGA" forKey:(__bridge id)kSecAttrService];
    [queryDictionary setObject:(__bridge id)(kSecAttrSynchronizableAny) forKey:(__bridge id)(kSecAttrSynchronizable)];
    [queryDictionary setObject:@YES forKey:(__bridge id)kSecReturnData];
    [queryDictionary setObject:(__bridge id)kSecMatchLimitOne forKey:(__bridge id)kSecMatchLimit];
    [queryDictionary setObject:(__bridge id)kSecAttrAccessibleAfterFirstUnlock forKey:(__bridge id)kSecAttrAccessible];

    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)queryDictionary, &result);

    switch (status) {
        case errSecSuccess: {
            NSString *uuidString = [[NSString alloc] initWithData:(__bridge_transfer NSData *)result encoding:NSUTF8StringEncoding];
            statsid->append([uuidString UTF8String]);
            break;
        }

        case errSecItemNotFound: {
            NSString *uuidString = [[[NSUUID alloc] init] UUIDString];

            NSData *uuidData = [uuidString dataUsingEncoding:NSUTF8StringEncoding];
            [queryDictionary setObject:uuidData forKey:(__bridge id)kSecValueData];
            [queryDictionary setObject:(__bridge id)kSecAttrAccessibleAfterFirstUnlock forKey:(__bridge id)kSecAttrAccessible];
            [queryDictionary removeObjectForKey:(__bridge id)kSecReturnData];
            [queryDictionary removeObjectForKey:(__bridge id)kSecMatchLimit];

            status = SecItemAdd((__bridge CFDictionaryRef)queryDictionary, NULL);

            switch (status) {
                case errSecSuccess: {
                    statsid->append([uuidString UTF8String]);
                    break;
                }
                case errSecDuplicateItem: {
                    [queryDictionary removeObjectForKey:(__bridge id)kSecAttrAccessible];
                    [queryDictionary setObject:@YES forKey:(__bridge id)kSecReturnData];
                    [queryDictionary setObject:(__bridge id)kSecMatchLimitOne forKey:(__bridge id)kSecMatchLimit];
                    
                    status = SecItemCopyMatching((__bridge CFDictionaryRef)queryDictionary, &result);
                    
                    switch (status) {
                        case errSecSuccess: {
                            NSString *uuidString = [[NSString alloc] initWithData:(__bridge_transfer NSData *)result encoding:NSUTF8StringEncoding];
                            statsid->append([uuidString UTF8String]);
                            break;
                        }
                    }
                    
                    [queryDictionary removeObjectForKey:(__bridge id)kSecReturnData];
                    [queryDictionary removeObjectForKey:(__bridge id)kSecMatchLimit];
                    NSMutableDictionary *attributesToUpdate = [[NSMutableDictionary alloc] init];
                    [attributesToUpdate setObject:(__bridge id)kSecAttrAccessibleAfterFirstUnlock forKey:(__bridge id)kSecAttrAccessible];
                    
                    status = SecItemUpdate((__bridge CFDictionaryRef)queryDictionary, (__bridge CFDictionaryRef)attributesToUpdate);
                    
                    switch (status) {
                        case errSecSuccess:
                            LOG_debug << "Update statsid keychain item to allow access it after first unlock";
                            break;
                            
                        default:
                            LOG_err << "SecItemUpdate failed with error code " << status;
                            break;
                    }
                    break;
                }
                default: {
                    LOG_err << "SecItemAdd failed with error code " << status;
                    break;
                }
            }
            break;
        }
        default: {
            LOG_err << "SecItemCopyMatching failed with error code " << status;
            break;
        }
    }
}

void ios_appbasepath(std::string *appbasepath) {
    appbasepath->assign([NSHomeDirectory() UTF8String]);
}
