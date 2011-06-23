//
//  SpeakerBoxxPlugin.h
//  SpeakerBoxx
//
//  Created by Jean-Pierre Mouilleseaux on 22 Jun 2011.
//  Copyright 2011 Chorded Constructions. All rights reserved.
//

#import <Quartz/Quartz.h>

@interface SpeakerBoxxPlugIn : QCPlugIn {
@private
    NSURL* _fileURL;
}
@property (nonatomic, assign) NSString* inputFileLocation;
@end
