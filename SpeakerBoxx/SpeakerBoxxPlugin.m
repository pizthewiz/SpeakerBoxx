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
        // VBR
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
    if (pAqData->mPlaybackState == SBPlaybackStateStopped && !pAqData->mShouldPrimeBuffers) {
        return;
    }

    UInt32 numBytesReadFromFile = 0, numPackets = pAqData->mNumPacketsToRead;
    OSStatus status = AudioFileReadPackets(pAqData->mAudioFile, false, &numBytesReadFromFile, pAqData->mPacketDescs, pAqData->mCurrentPacket, &numPackets, inBuffer->mAudioData);
    if (status != noErr) {
        CCErrorLog(@"ERROR - failed to read packets from audio file with error %d", (int)status);
        return;
    }

    // enqueue the next chunk
    if (numPackets > 0) {
        inBuffer->mAudioDataByteSize = numBytesReadFromFile;
        status = AudioQueueEnqueueBuffer(pAqData->mQueue, inBuffer, (pAqData->mPacketDescs ? numPackets : 0), pAqData->mPacketDescs);
        if (status != noErr) {
            CCErrorLog(@"ERROR - failed to enqueue buffer with error %d", (int)status);
            return;
        }
        pAqData->mCurrentPacket += numPackets;
    }
    // stop when at the end
    else {
        AudioQueueStop(pAqData->mQueue, false);
        pAqData->mPlaybackState = SBPlaybackStateStopped;
        return;
    }
}

#pragma mark - PLUGIN

// WORKAROUND - radar://problem/9927446 Lion added QCPlugInAttribute key constants not weak linked
#pragma weak QCPlugInAttributeCategoriesKey
#pragma weak QCPlugInAttributeExamplesKey

static NSString* const SBExampleCompositionName = @"Audio Player";

static double SBGainDefault = 1.0;

struct AQPlayerState aqData;

@interface SpeakerBoxxPlugIn()
@property (nonatomic, retain) NSURL* fileURL;
- (void)_setupQueue;
- (void)_startQueue;
- (void)_stopQueue;
- (void)_pauseQueue;
- (void)_resetQueueToPacket:(NSUInteger)packet;
- (void)_cleanupQueue;
- (void)_setQueueGain;
@end

@implementation SpeakerBoxxPlugIn

@dynamic inputFileLocation, inputPlaySignal, inputPlayFromBeginningSignal, inputPauseSignal, inputStopSignal, inputGain;
@synthesize fileURL = _fileURL;

+ (NSDictionary*)attributes {
    NSMutableDictionary* attributes = [NSMutableDictionary dictionaryWithObjectsAndKeys: 
        CCLocalizedString(@"kQCPlugIn_Name", NULL), QCPlugInAttributeNameKey, 
        CCLocalizedString(@"kQCPlugIn_Description", NULL), QCPlugInAttributeDescriptionKey, 
        nil];

#if defined(MAC_OS_X_VERSION_10_7) && (MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_7)
    if (&QCPlugInAttributeCategoriesKey != NULL) {
        // array with category strings
        NSArray* categories = [NSArray arrayWithObjects:@"Render", @"Destination", nil];
        [attributes setObject:categories forKey:QCPlugInAttributeCategoriesKey];
    }
    if (&QCPlugInAttributeExamplesKey != NULL) {
        // array of file paths or urls relative to plugin resources
        NSArray* examples = [NSArray arrayWithObjects:[[NSBundle bundleForClass:[self class]] URLForResource:SBExampleCompositionName withExtension:@"qtz"], nil];
        [attributes setObject:examples forKey:QCPlugInAttributeExamplesKey];
    }
#endif

    return (NSDictionary*)attributes;
}

+ (NSDictionary*)attributesForPropertyPortWithKey:(NSString*)key {
    if ([key isEqualToString:@"inputFileLocation"])
        return [NSDictionary dictionaryWithObjectsAndKeys:@"File Location", QCPortAttributeNameKey, nil];
    else if ([key isEqualToString:@"inputPlaySignal"])
        return [NSDictionary dictionaryWithObjectsAndKeys:@"Play Signal", QCPortAttributeNameKey, nil];
    else if ([key isEqualToString:@"inputPlayFromBeginningSignal"])
        return [NSDictionary dictionaryWithObjectsAndKeys:@"Play From The Beginning Signal", QCPortAttributeNameKey, nil];
    else if ([key isEqualToString:@"inputPauseSignal"])
        return [NSDictionary dictionaryWithObjectsAndKeys:@"Pause Signal", QCPortAttributeNameKey, nil];
    else if ([key isEqualToString:@"inputStopSignal"])
        return [NSDictionary dictionaryWithObjectsAndKeys:@"Stop Signal", QCPortAttributeNameKey, nil];
    else if ([key isEqualToString:@"inputGain"])
        return [NSDictionary dictionaryWithObjectsAndKeys:@"Gain", QCPortAttributeNameKey, 
            [NSNumber numberWithDouble:0], QCPortAttributeMinimumValueKey, 
            [NSNumber numberWithDouble:1.0], QCPortAttributeMaximumValueKey, 
            [NSNumber numberWithDouble:SBGainDefault], QCPortAttributeDefaultValueKey, nil];
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
        _gain = SBGainDefault;
    }
    return self;
}

- (void)dealloc {
    [self _cleanupQueue];
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

    if (_playSignal && _aqData.mQueue)
        [self _startQueue];
}

- (BOOL)execute:(id <QCPlugInContext>)context atTime:(NSTimeInterval)time withArguments:(NSDictionary*)arguments {
    // quick bail
    if (!([self didValueForInputKeyChange:@"inputFileLocation"] || [self didValueForInputKeyChange:@"inputPlaySignal"] || [self didValueForInputKeyChange:@"inputPlayFromBeginningSignal"] || [self didValueForInputKeyChange:@"inputPauseSignal"] || [self didValueForInputKeyChange:@"inputStopSignal"] || [self didValueForInputKeyChange:@"inputGain"]) || [self.inputFileLocation isEqualToString:@""])
        return YES;

    if ([self didValueForInputKeyChange:@"inputFileLocation"]) {
        [self _cleanupQueue];

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

        self.fileURL = url;

        // TODO - may be better to just let it fail later?
        if (![url checkResourceIsReachableAndReturnError:NULL]) {
            return YES;
        }

        [self _setupQueue];

        if (self.inputPlaySignal)
            [self _startQueue];
    }
    if ([self didValueForInputKeyChange:@"inputPlaySignal"] && self.inputPlaySignal) {
        // setup when necessary
        if (!_aqData.mQueue)
            [self _setupQueue];
        [self _startQueue];
    }
    if ([self didValueForInputKeyChange:@"inputPlayFromBeginningSignal"] && self.inputPlayFromBeginningSignal) {
        // setup when necessary
        if (!_aqData.mQueue)
            [self _setupQueue];
        else
            [self _resetQueueToPacket:0];
        [self _startQueue];
    }
    if ([self didValueForInputKeyChange:@"inputPauseSignal"] && self.inputPauseSignal) {
        [self _pauseQueue];
    }
    if ([self didValueForInputKeyChange:@"inputStopSignal"] && self.inputStopSignal) {
        [self _stopQueue];
        [self _resetQueueToPacket:0];
    }
    if ([self didValueForInputKeyChange:@"inputGain"]) {
        _gain = self.inputGain;
        [self _setQueueGain];
    }

    CCDebugLogSelector();

	return YES;
}

- (void)disableExecution:(id <QCPlugInContext>)context {
	/*
	Called by Quartz Composer when the plug-in instance stops being used by Quartz Composer.
	*/

    CCDebugLogSelector();

    if (_aqData.mPlaybackState != SBPlaybackStateStopped)
        [self _cleanupQueue];
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
        CCErrorLog(@"ERROR - failed to open audio file %@ with error %d", self.fileURL, (int)status);
        return;
    }

    // fetch data format
    UInt32 dataFormatSize = sizeof(_aqData.mDataFormat);
    status = AudioFileGetProperty(_aqData.mAudioFile, kAudioFilePropertyDataFormat, &dataFormatSize, &_aqData.mDataFormat);
    if (status != noErr) {
        CCErrorLog(@"ERROR - failed to get data format property on audio file %@ with error %d", self.fileURL, (int)status);
    }

    // create queue
    status = AudioQueueNewOutput(&_aqData.mDataFormat, HandleOutputBuffer, &_aqData, CFRunLoopGetCurrent(), kCFRunLoopCommonModes, 0, &_aqData.mQueue);
    if (status != noErr) {
        CCErrorLog(@"ERROR - failed to create audio queue for audio file %@ with error %d", self.fileURL, (int)status);
    }

    // sort out buffer needs
    UInt32 maxPacketSize = 0, propertySize = sizeof(maxPacketSize);
    status = AudioFileGetProperty(_aqData.mAudioFile, kAudioFilePropertyPacketSizeUpperBound, &propertySize, &maxPacketSize);
    if (status != noErr) {
        CCErrorLog(@"ERROR - failed to get packet upper bound size for audio file %@ with error %d", self.fileURL, (int)status);
    }
#define SBBufferDurationSeconds 0.5
    DeriveBufferSize(_aqData.mDataFormat, maxPacketSize, SBBufferDurationSeconds, &_aqData.bufferByteSize, &_aqData.mNumPacketsToRead);

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
            CCErrorLog(@"ERROR - failed to allocate queue buffer with error %d", (int)status);
        }
        _aqData.mShouldPrimeBuffers = true;
        HandleOutputBuffer(&_aqData, _aqData.mQueue, _aqData.mBuffers[idx]);
        _aqData.mShouldPrimeBuffers = false;
    }

    // set gain
    [self _setQueueGain];
}

- (void)_startQueue {
    CCDebugLogSelector();

    if (!_aqData.mQueue) {
        CCErrorLog(@"ERROR - failed to start queue, queue not setup!");
        return;
    }

    if (_aqData.mPlaybackState == SBPlaybackStatePlaying) {
        CCWarningLog(@"WARNING - queue already running, cannot run while runnning");
        return;
    }

    _aqData.mPlaybackState = SBPlaybackStatePlaying;
    OSStatus status = AudioQueueStart(_aqData.mQueue, NULL);
    if (status != noErr) {
        CCErrorLog(@"ERROR - failed to start queue with error %d", (int)status);
    }
}

- (void)_pauseQueue {
    CCDebugLogSelector();

    if (_aqData.mPlaybackState != SBPlaybackStatePlaying) {
        CCWarningLog(@"WARNING - queue not running, pause is unnecessary");
        return;
    }

    OSStatus status = AudioQueuePause(_aqData.mQueue);
    if (status != noErr) {
        CCErrorLog(@"ERROR - failed to pause queue with error %d", (int)status);
    }
    _aqData.mPlaybackState = SBPlaybackStatePaused;
}

- (void)_stopQueue {
    CCDebugLogSelector();

    if (_aqData.mPlaybackState != SBPlaybackStatePlaying) {
        CCWarningLog(@"WARNING - queue not running, stop is unnecessary");
        return;
    }

    OSStatus status = AudioQueueStop(_aqData.mQueue, true);
    if (status != noErr) {
        CCErrorLog(@"ERROR - failed to stop queue with error %d", (int)status);
        return;
    }
    _aqData.mPlaybackState = SBPlaybackStateStopped;
}

- (void)_resetQueueToPacket:(NSUInteger)packet {
    CCDebugLogSelector();

    if (!_aqData.mQueue) {
        CCErrorLog(@"ERROR - failed to reset queue, queue not setup!");
        return;
    }

    if (_aqData.mPlaybackState != SBPlaybackStateStopped) {
        [self _stopQueue];
    }

    _aqData.mCurrentPacket = packet;
    _aqData.mShouldPrimeBuffers = true;
    for (NSUInteger idx = 0; idx < kNumberBuffers; ++idx) {
        HandleOutputBuffer(&_aqData, _aqData.mQueue, _aqData.mBuffers[idx]);
    }
    _aqData.mShouldPrimeBuffers = false;
}

- (void)_cleanupQueue {
    CCDebugLogSelector();

    if (_aqData.mPlaybackState != SBPlaybackStateStopped) {
        [self _stopQueue];
    }

    AudioQueueDispose(_aqData.mQueue, true);
    _aqData.mQueue = NULL;
    AudioFileClose(aqData.mAudioFile);
    aqData.mAudioFile = NULL;
    free(aqData.mPacketDescs);
    aqData.mPacketDescs = NULL;
}

- (void)_setQueueGain {
    CCDebugLogSelector();

    if (!_aqData.mQueue) {
        CCWarningLog(@"WARNING - failed to set queue gain, queue not setup!");
        return;
    }

    Float32 gain = _gain;
    OSStatus status = AudioQueueSetParameter(_aqData.mQueue, kAudioQueueParam_Volume, gain);
    if (status != noErr) {
        CCErrorLog(@"ERROR - failed to set queue gain to %f with error %d", gain, (int)status);
    }
}

@end
