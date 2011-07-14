//
//  SpeakerBoxxPlugin.h
//  SpeakerBoxx
//
//  Created by Jean-Pierre Mouilleseaux on 22 Jun 2011.
//  Copyright 2011 Chorded Constructions. All rights reserved.
//

#import <Quartz/Quartz.h>
#import <AudioToolbox/AudioQueue.h>

typedef enum {
    SBPlaybackStateStopped = 0,
    SBPlaybackStatePlaying = 1 << 1,
    SBPlaybackStatePaused = 1 << 2
} SBPlaybackState;

// yoinked from http://developer.apple.com/library/mac/#documentation/MusicAudio/Conceptual/AudioQueueProgrammingGuide/AQPlayback/PlayingAudio.html
static const int kNumberBuffers = 3;
struct AQPlayerState {
    AudioStreamBasicDescription mDataFormat;
    AudioQueueRef mQueue;
    AudioQueueBufferRef mBuffers[kNumberBuffers];
    AudioFileID mAudioFile;
    UInt32 bufferByteSize;
    SInt64 mCurrentPacket;
    UInt32 mNumPacketsToRead;
    AudioStreamPacketDescription* mPacketDescs;
    SBPlaybackState mPlaybackState;
    bool mShouldPrimeBuffers;
};

@interface SpeakerBoxxPlugIn : QCPlugIn {
@private
    struct AQPlayerState _aqData;
    NSURL* _fileURL;
    BOOL _playSignal;
    double _gain;
}
@property (nonatomic, assign) NSString* inputFileLocation;
@property (nonatomic) BOOL inputPlaySignal;
@property (nonatomic) BOOL inputPauseSignal;
@property (nonatomic) BOOL inputStopSignal;
@property (nonatomic) double inputGain;
@end
