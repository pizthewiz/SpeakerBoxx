//
//  SpeakerBoxxPlugIn.m
//  SpeakerBoxx
//
//  Created by Jean-Pierre Mouilleseaux on 22 Jun 2011.
//  Copyright 2011 Chorded Constructions. All rights reserved.
//

#import "SpeakerBoxxPlugIn.h"
#import "SpeakerBoxx.h"

#pragma mark AUDIOQUEUE

static void DeriveBufferSize(AudioStreamBasicDescription ASBDesc, UInt32 maxPacketSize, Float64 seconds, UInt32* outBufferSize, UInt32* outNumPacketsToRead) {
    CCDebugLog(@"DeriveBufferSize()");

    static const int maxBufferSize = 0x50000;
    static const int minBufferSize = 0x4000;

    if (ASBDesc.mFramesPerPacket != 0) {
        Float64 numPacketsForTime = ASBDesc.mSampleRate / ASBDesc.mFramesPerPacket * seconds;
        *outBufferSize = numPacketsForTime * maxPacketSize;
    } else {
        *outBufferSize = maxBufferSize > maxPacketSize ? maxBufferSize : maxPacketSize;
    }

    if (*outBufferSize > maxBufferSize && *outBufferSize > maxPacketSize) {
        *outBufferSize = maxBufferSize;
    } else if (*outBufferSize < minBufferSize) {
        *outBufferSize = minBufferSize;
    }

    *outNumPacketsToRead = *outBufferSize / maxPacketSize;
}


static void HandleOutputBuffer(void* aqData, AudioQueueRef inAQ, AudioQueueBufferRef inBuffer) {
    CCDebugLog(@"HandleOutputBuffer()");

    struct AQPlayerState* pAqData = aqData;
    if (!pAqData->mIsRunning) {
        return;
    }

    UInt32 numBytesReadFromFile = 0, numPackets = pAqData->mNumPacketsToRead;
    OSStatus status = AudioFileReadPackets(pAqData->mAudioFile, false, &numBytesReadFromFile, pAqData->mPacketDescs, pAqData->mCurrentPacket, &numPackets, inBuffer->mAudioData);
    if (status != noErr) {
        CCErrorLog(@"ERROR - failed to read packets from audio file");
        return;
    }

    // stop when at the end
    if (numPackets == 0) {
        AudioQueueStop (pAqData->mQueue, false);
        pAqData->mIsRunning = false;
        return;
    }

    // enqueue data
    inBuffer->mAudioDataByteSize = numBytesReadFromFile;
    status = AudioQueueEnqueueBuffer(pAqData->mQueue, inBuffer, (pAqData->mPacketDescs ? numPackets : 0), pAqData->mPacketDescs);
    if (status != noErr) {
        CCErrorLog(@"ERROR - failed to enqueue buffer");
        return;
    }

}

#pragma mark - PLUGIN

static NSString* const SBExampleCompositionName = @"";

struct AQPlayerState aqData;

@interface SpeakerBoxxPlugIn()
@property (nonatomic, retain) NSURL* fileURL;
- (void)_setupQueue;
- (void)_startQueue;
- (void)_stopQueue;
- (void)_cleanupQueue;
@end

@implementation SpeakerBoxxPlugIn

@dynamic inputFileLocation;
@synthesize fileURL = _fileURL;

+ (NSDictionary*)attributes {
    NSMutableDictionary* attributes = [NSDictionary dictionaryWithObjectsAndKeys: 
        CCLocalizedString(@"kQCPlugIn_Name", NULL), QCPlugInAttributeNameKey, 
        CCLocalizedString(@"kQCPlugIn_Description", NULL), QCPlugInAttributeDescriptionKey, 
        nil];

#if defined(MAC_OS_X_VERSION_10_7) && (MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_7)
    if (&QCPlugInAttributeCategoriesKey != NULL) {
        // array with category strings
        NSArray* categories = [NSArray arrayWithObjects:@"obviously", @"fake", nil];
        [attributes setObject:categories forKey:QCPlugInAttributeCategoriesKey];
    }
    if (&QCPlugInAttributeExamplesKey != NULL) {
        // array of file paths or urls relative to plugin resources
        NSArray* examples = [NSArray arrayWithObjects:[[NSBundle mainBundle] URLForResource:SBExampleCompositionName withExtension:@"qtz"], nil];
        [attributes setObject:examples forKey:QCPlugInAttributeExamplesKey];
    }
#endif

    return (NSDictionary*)attributes;
}

+ (NSDictionary*)attributesForPropertyPortWithKey:(NSString*)key {
    if ([key isEqualToString:@"inputFileLocation"])
        return [NSDictionary dictionaryWithObjectsAndKeys:@"File Location", QCPortAttributeNameKey, nil];
	return nil;
}

+ (QCPlugInExecutionMode)executionMode {
	return kQCPlugInExecutionModeConsumer;
}

+ (QCPlugInTimeMode)timeMode {
	return kQCPlugInTimeModeIdle;
}

#pragma mark -

- (id)init {
	self = [super init];
	if (self) {
	}	
	return self;
}

- (void)dealloc {
    if (_aqData.mPacketDescs)
        free(_aqData.mPacketDescs);

    [_fileURL release];

	[super dealloc];
}

#pragma mark - EXECUTION

- (BOOL)startExecution:(id <QCPlugInContext>)context {
	/*
	Called by Quartz Composer when rendering of the composition starts: perform any required setup for the plug-in.
	Return NO in case of fatal failure (this will prevent rendering of the composition to start).
	*/

	return YES;
}

- (void)enableExecution:(id <QCPlugInContext>)context {
	/*
	Called by Quartz Composer when the plug-in instance starts being used by Quartz Composer.
	*/
}

- (BOOL)execute:(id <QCPlugInContext>)context atTime:(NSTimeInterval)time withArguments:(NSDictionary*)arguments {
    // process input only when the file location changes
    if (![self didValueForInputKeyChange:@"inputFileLocation"])
        return YES;

    // bail on empty location
    if ([self.inputFileLocation isEqualToString:@""])
        return YES;

    NSURL* url = [NSURL URLWithString:self.inputFileLocation];
    if (![url isFileURL]) {
        NSString* path = [self.inputFileLocation stringByStandardizingPath];
        if ([path isAbsolutePath]) {
            url = [NSURL fileURLWithPath:path isDirectory:NO];
        } else {
            NSURL* baseDirectoryURL = [[context compositionURL] URLByDeletingLastPathComponent];
            url = [baseDirectoryURL URLByAppendingPathComponent:path];
        }        
    }

    // TODO - may be better to just let it fail later?
//    if (![url checkResourceIsReachableAndReturnError:NULL])
//        return YES;

    CCDebugLogSelector();

    self.fileURL = url;
    [self _setupQueue];

	return YES;
}

- (void)disableExecution:(id <QCPlugInContext>)context {
	/*
	Called by Quartz Composer when the plug-in instance stops being used by Quartz Composer.
	*/
}

- (void)stopExecution:(id <QCPlugInContext>)context {
	/*
	Called by Quartz Composer when rendering of the composition stops: perform any required cleanup for the plug-in.
	*/
}

#pragma mark -

- (void)_setupQueue {
    CCDebugLogSelector();

    [self _cleanupQueue];

    // open file
    OSStatus status = AudioFileOpenURL((CFURLRef)self.fileURL, fsRdPerm, 0, &_aqData.mAudioFile);
    if (status != noErr) {
        CCErrorLog(@"ERROR - failed to open audio file %@", self.fileURL);
        return;
    }

    // fetch data format
    UInt32 dataFormatSize = sizeof(_aqData.mDataFormat);
    status = AudioFileGetProperty(_aqData.mAudioFile, kAudioFilePropertyDataFormat, &dataFormatSize, &_aqData.mDataFormat);
    if (status != noErr) {
        CCErrorLog(@"ERROR - failed to get data format property on audio file %@", self.fileURL);
    }

    // create queue
    status = AudioQueueNewOutput(&_aqData.mDataFormat, HandleOutputBuffer, &_aqData, CFRunLoopGetCurrent(), kCFRunLoopCommonModes, 0, &_aqData.mQueue);
    if (status != noErr) {
        CCErrorLog(@"ERROR - failed to create audio queue for audio file %@", self.fileURL);
    }

    // sort out buffer needs
    UInt32 maxPacketSize = 0, propertySize = sizeof(maxPacketSize);
    status = AudioFileGetProperty(_aqData.mAudioFile, kAudioFilePropertyPacketSizeUpperBound, &propertySize, &maxPacketSize);
    if (status != noErr) {
        CCErrorLog(@"ERROR - failed to get packet upper bound size for audio file %@", self.fileURL);
    }
    DeriveBufferSize(_aqData.mDataFormat, maxPacketSize, 0.5, &_aqData.bufferByteSize, &_aqData.mNumPacketsToRead);

    BOOL isFormatVBR = _aqData.mDataFormat.mBytesPerPacket == 0 || _aqData.mDataFormat.mFramesPerPacket == 0;
    if (isFormatVBR) {
        _aqData.mPacketDescs = (AudioStreamPacketDescription*)malloc(_aqData.mNumPacketsToRead * sizeof(AudioStreamPacketDescription));
    } else {
        _aqData.mPacketDescs = NULL;
    }

    // smash and grab magic cookie for formats that support it
    UInt32 cookieSize = sizeof(UInt32);
    status = AudioFileGetPropertyInfo(_aqData.mAudioFile, kAudioFilePropertyMagicCookieData, &cookieSize, NULL);
    if (status == noErr && cookieSize) {
        char* magicCookie = (char *) malloc(cookieSize);
        AudioFileGetProperty(_aqData.mAudioFile, kAudioFilePropertyMagicCookieData, &cookieSize, magicCookie);
        AudioQueueSetProperty(_aqData.mQueue, kAudioQueueProperty_MagicCookie, magicCookie, cookieSize);        
        free (magicCookie);
    }

    // allocate and prime buffers
    _aqData.mCurrentPacket = 0;
    for (NSUInteger idx = 0; idx < kNumberBuffers; ++idx) {
        status = AudioQueueAllocateBuffer(_aqData.mQueue, _aqData.bufferByteSize, &_aqData.mBuffers[idx]);
        if (status != noErr) {
            CCErrorLog(@"ERROR - failed to allocate queue buffer");
        }
        HandleOutputBuffer(&_aqData, _aqData.mQueue, _aqData.mBuffers[idx]);
    }

    // set gain
    Float32 gain = 1.0;
    // Optionally, allow user to override gain setting here
    status = AudioQueueSetParameter(_aqData.mQueue, kAudioQueueParam_Volume, gain);
    if (status != noErr) {
        CCErrorLog(@"ERROR - failed to set queue gain to %f", gain);
    }

    // kickstart playback
    [self _startQueue];
}

- (void)_startQueue {
    CCDebugLogSelector();

    _aqData.mIsRunning = true;
    OSStatus status = AudioQueueStart(_aqData.mQueue, NULL);
    if (status != noErr) {
        CCErrorLog(@"ERROR - failed to start queue");
    }
    do {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.25, false);
    } while (_aqData.mIsRunning);
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1, false);    
}

- (void)_stopQueue {
    CCDebugLogSelector();

    AudioQueueStop(_aqData.mQueue, false);
    _aqData.mIsRunning = false;
}

- (void)_cleanupQueue {
    CCDebugLogSelector();

    if (_aqData.mIsRunning) {
        [self _stopQueue];
    }

    AudioQueueDispose(_aqData.mQueue, true);
    AudioFileClose(aqData.mAudioFile);
    free (aqData.mPacketDescs);
}

@end
