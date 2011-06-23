//
//  SpeakerBoxxPlugIn.m
//  SpeakerBoxx
//
//  Created by Jean-Pierre Mouilleseaux on 22 Jun 2011.
//  Copyright 2011 Chorded Constructions. All rights reserved.
//

#import "SpeakerBoxxPlugIn.h"
#import "SpeakerBoxx.h"

#define	kQCPlugIn_Name				@"Audio Player"
#define	kQCPlugIn_Description		@"SpeakerBoxx description"

@interface SpeakerBoxxPlugIn()
@property (nonatomic, retain) NSURL* fileURL;
@end

@implementation SpeakerBoxxPlugIn

@dynamic inputFileLocation;
@synthesize fileURL = _fileURL;

+ (NSDictionary*)attributes {
	return [NSDictionary dictionaryWithObjectsAndKeys:kQCPlugIn_Name, QCPlugInAttributeNameKey, kQCPlugIn_Description, QCPlugInAttributeDescriptionKey, nil];
}

+ (NSDictionary *)attributesForPropertyPortWithKey:(NSString*)key {
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

- (void)finalize {
    [_fileURL release];

	[super finalize];
}

- (void)dealloc {
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
    if (![url isFileURL])
        url = [NSURL fileURLWithPath:[self.inputFileLocation stringByExpandingTildeInPath] isDirectory:NO];

    // TODO - may be better to just let it fail later?
//    if (![url checkResourceIsReachableAndReturnError:NULL])
//        return YES;

    CCDebugLogSelector();

    self.fileURL = url;

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

@end
