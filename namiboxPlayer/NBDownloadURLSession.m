//
//  NBDownloadURLSession.m
//  namiboxVideo
//
//  Created by 刘勇强 on 16/12/5.
//  Copyright © 2016年 namibox. All rights reserved.
//

#import "NBDownloadURLSession.h"
#import "NBPlayerDefine.h"
#import "NBPlayer.h"
#import "NBPlayerM3U8Handler.h"
#import "HTTPServer.h"
#import "NBPlayerEnvironment.h"

static NSInteger const sPlayAfterCacheCount = 3;

@interface NBDownloadURLSession()<NSURLSessionDownloadDelegate> {
    NSURLSession *session;
    NSString *_playUrl; // 其他格式的文件的url
    NSMutableArray *_urlsWidthDownloaded; // hls中ts文件已经下载的url
    NSMutableArray *_segmentInfos;
    NSInteger _downloadedIndex;
}

@end

@implementation NBDownloadURLSession

- (instancetype)init {
    if (self == [super init]) {
        _startPlay = NO;
        _urlsWidthDownloaded = [[NSMutableArray alloc] init];
        _segmentInfos = [[NSMutableArray alloc] init];
        
        [session invalidateAndCancel];
        session = nil;
        NSURLSessionConfiguration *sessionConfiguration = [NSURLSessionConfiguration defaultSessionConfiguration];
        sessionConfiguration.timeoutIntervalForRequest = 1000;
        session = [NSURLSession sessionWithConfiguration:sessionConfiguration delegate:self delegateQueue:[NSOperationQueue mainQueue]];
        
        [self addObserver:self forKeyPath:@"currentIndex" options:NSKeyValueObservingOptionNew context:DownloadKVOContext];
    }
    return self;
}

- (void)addDownloadTask:(NSString *)playUrl {
    _playUrl = playUrl;
    // for hls 格式视频
    if (_segmentInfo) {
        [_segmentInfos addObject:_segmentInfo];
    }
    
    NSURL * url = [NSURL URLWithString:playUrl];
    NSURLRequest * request = [NSURLRequest requestWithURL:url];
    NSURLSessionDownloadTask * downloadTask = [session downloadTaskWithRequest:request];
    [downloadTask resume];
    NSLog(@"%@",@"添加task");
}

// Handle download completion from the task
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didFinishDownloadingToURL:(NSURL *)location {
    // 存储地址
    NSString *cachePath = @"";
    
    if (currentCacheType == NBPlayerCacheTypePlayHLS) {
        NSURL *url = downloadTask.response.URL;
        // 已经下载的url
        [_urlsWidthDownloaded addObject:url];
        
        _downloadedIndex = [self.hlsUrls indexOfObject:url];
        
        cachePath =  [cachePathForVideo stringByAppendingPathComponent:[NSString stringWithFormat:@"%ld.ts",(long)_downloadedIndex]];
        
        self.downloadProgress = (double)_urlsWidthDownloaded.count/(double)self.hlsUrls.count;
        
        // 当缓存的数量－当前播放的数量 ＝ 3.开始播放
        if (_urlsWidthDownloaded.count - self.currentIndex == sPlayAfterCacheCount) {
            if (!self.startPlay) {
                self.startPlay = YES;
            }
        }
        
        if (self.nextTs < sPlayAfterCacheCount) {
            self.nextTs = _downloadedIndex + 1;
        }
        
    } else {
        cachePath = saveCachePathForVideo(_playUrl);
    }
    
    // Copy temporary file
    NSError * error;
    [[NSFileManager defaultManager] copyItemAtURL:location toURL:[NSURL fileURLWithPath:cachePath] error:&error];
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didResumeAtOffset:(int64_t)fileOffset expectedTotalBytes:(int64_t)expectedTotalBytes {
    // Required delegate method
}

// Handle task completion
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (error) {
        NSLog(@"Task %@ failed: %@", task, error);
        return;
    }
    
    if (currentCacheType != NBPlayerCacheTypePlayHLS) {
        // 下载完成，开始播放
        self.startPlay = YES;
    }
}

// Handle progress update from the task
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    // Update UI,更新进度条
    
    int64_t kReceived = downloadTask.countOfBytesReceived / 1024;
    int64_t kExpected = downloadTask.countOfBytesExpectedToReceive / 1024;
    NSString *statusString = [NSString stringWithFormat:@"%lldk of %lldk", kReceived, kExpected];
    NSLog(@"进度: %@",statusString);
    
    if (!self.downloadProgress) {
        self.downloadProgress = 0;
    }
    
    if (currentCacheType != NBPlayerCacheTypePlayHLS) {
        double progress = (double) downloadTask.countOfBytesReceived / (double)downloadTask.countOfBytesExpectedToReceive;
        
        self.downloadProgress = progress;
    }
}

-(NSString*)createLocalM3U8file {
    
    NSString *fullpath = [cachePathForVideo stringByAppendingPathComponent:cacheVieoName];
    
//    NSFileManager *fileManager = [NSFileManager defaultManager];
//    if (![fileManager fileExistsAtPath:fullpath]) {
//        return nil;
//    }
    
    //创建文件头部
    __block NSString* head = @"#EXTM3U\n#EXT-X-TARGETDURATION:30\n#EXT-X-VERSION:2\n#EXT-X-DISCONTINUITY\n";
    
    [_segmentInfos enumerateObjectsUsingBlock:^(M3U8SegmentInfo *obj, NSUInteger idx, BOOL * _Nonnull stop) {
        NSString* length = [NSString stringWithFormat:@"#EXTINF:%ld,\n",(long)obj.duration];
        head = [NSString stringWithFormat:@"%@%@%@\n",head,length,obj.locationUrl];
    }];
    //创建尾部
    NSString* end = @"#EXT-X-ENDLIST";
    head = [head stringByAppendingString:end];
    NSMutableData *writer = [[NSMutableData alloc] init];
    [writer appendData:[head dataUsingEncoding:NSUTF8StringEncoding]];
    
    NSError *error;
    BOOL bSucc =[writer writeToFile:fullpath options:(NSDataWritingAtomic )  error:&error];
    
    
    if(bSucc) {
        NSLog(@"create m3u8file succeed; fullpath:%@, content:%@",fullpath,head);
        return  fullpath;
    } else {
        NSLog(@"create m3u8file failed:%@", error);
        return  nil;
    }
    return nil;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    if (context == DownloadKVOContext) {
        if ([keyPath isEqualToString:@"currentIndex"]) {
            if (_downloadedIndex+1 < self.hlsUrls.count && _urlsWidthDownloaded.count - self.currentIndex < 3 ) {
                if (self.nextTs != _downloadedIndex +1) {
                    self.nextTs = _downloadedIndex + 1;
                }
                
                NSLog(@"开始缓存下一个：%ld",(long)self.nextTs);
            }
            return;
        }
    }
}

- (void)cancel {
    [session invalidateAndCancel];
    session = nil;
}

- (void)dealloc {
    NSLog(@"%@",@"NBDownloadUrlSession dealloc");
    [self cancel];
}

@end
