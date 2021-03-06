// Copyright (c) 2015, the Fletch project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "Immi.h"

@protocol ImageCache
- (id)get:(NSString*)key;
- (id)put:(NSString*)key value:(id)value;
@end

@interface ImagePresenter : UIImageView <ImagePresenter>
- (void)presentImage:(ImageNode*)node;
- (void)presentImageFromData:(NSData*)data;
- (void)setCache:(id<ImageCache>)cache;
- (void)setDefaultImage:(UIImage*)image;
@end

