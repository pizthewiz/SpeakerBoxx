//
//  SpeakerBoxxPlugin.h
//  SpeakerBoxx
//
//  Created by Jean-Pierre Mouilleseaux on 22 Jun 2011.
//  Copyright 2011 Chorded Constructions. All rights reserved.
//

#import <Quartz/Quartz.h>
#import <AudioToolbox/AudioQueue.h>

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
    bool mIsRunning;
};

@interface SpeakerBoxxPlugIn : QCPlugIn {
@private
    struct AQPlayerState _aqData;
    NSURL* _fileURL;
}
@property (nonatomic, assign) NSString* inputFileLocation;
@end
