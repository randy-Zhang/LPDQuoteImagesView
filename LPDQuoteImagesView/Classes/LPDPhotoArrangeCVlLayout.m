//
//  LPDPickPhotoCellLayout.m
//  LPDQuoteSystemImagesController
//
//  Created by Assuner on 2016/12/16.
//  Copyright © 2016年 Assuner. All rights reserved.
//

#import "LPDPhotoArrangeCVlLayout.h"
#import "LPDPhotoArrangeCell.h"
#import "ZDeleteRegionView.h"

#define stringify   __STRING

static CGFloat const PRESS_TO_MOVE_MIN_DURATION = 0.5;
static CGFloat const MIN_PRESS_TO_BEGIN_EDITING_DURATION = 0.6;

CG_INLINE CGPoint CGPointOffset(CGPoint point, CGFloat dx, CGFloat dy)
{
    return CGPointMake(point.x + dx, point.y + dy);
}

@interface LPDPhotoArrangeCVlLayout () <UIGestureRecognizerDelegate>

/** 删除视图*/
@property (nonatomic, strong) ZDeleteRegionView *deleteRegionView;


@property (nonatomic,readonly) id<LPDPhotoArrangeCVDataSource> dataSource;
@property (nonatomic,readonly) id<LPDPhotoArrangeCVFlowLayout> delegate;

@end

@implementation LPDPhotoArrangeCVlLayout

{
    UILongPressGestureRecognizer * _longPressGestureRecognizer;
    UIPanGestureRecognizer * _panGestureRecognizer;
    NSIndexPath * _movingItemIndexPath;
    UIView * _beingMovedPromptView;
    CGPoint _sourceItemCollectionViewCellCenter;
    
    CADisplayLink * _displayLink;
    CFTimeInterval _remainSecondsToBeginEditing;
}
#pragma mark - setup

- (void)dealloc
{
    [_displayLink invalidate];
    
    [self removeGestureRecognizers];
    [self removeObserver:self forKeyPath:@stringify(collectionView)];
}

- (instancetype)init
{
    if (self = [super init]) {
        [self setup];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if (self = [super initWithCoder:coder]) {
        [self setup];
    }
    return self;
}

- (void)setup
{
    [self addObserver:self forKeyPath:@stringify(collectionView) options:NSKeyValueObservingOptionNew context:nil];
}

- (void)addGestureRecognizers
{
    self.collectionView.userInteractionEnabled = YES;
    
    _longPressGestureRecognizer = [[UILongPressGestureRecognizer alloc]initWithTarget:self action:@selector(longPressGestureRecognizerTriggerd:)];
    _longPressGestureRecognizer.cancelsTouchesInView = NO;
    _longPressGestureRecognizer.minimumPressDuration = PRESS_TO_MOVE_MIN_DURATION;
    _longPressGestureRecognizer.delegate = self;
    
    for (UIGestureRecognizer * gestureRecognizer in self.collectionView.gestureRecognizers) {
        if ([gestureRecognizer isKindOfClass:[UILongPressGestureRecognizer class]]) {
            [gestureRecognizer requireGestureRecognizerToFail:_longPressGestureRecognizer];
        }
    }
    
    [self.collectionView addGestureRecognizer:_longPressGestureRecognizer];
    
    //    _panGestureRecognizer = [[UIPanGestureRecognizer alloc]initWithTarget:self action:@selector(panGestureRecognizerTriggerd:)];
    //    _panGestureRecognizer.delegate = self;
    //    [self.collectionView addGestureRecognizer:_panGestureRecognizer];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationWillResignActive:) name:UIApplicationWillResignActiveNotification object:nil];
}

- (void)removeGestureRecognizers
{
    if (_longPressGestureRecognizer) {
        if (_longPressGestureRecognizer.view) {
            [_longPressGestureRecognizer.view removeGestureRecognizer:_longPressGestureRecognizer];
        }
        _longPressGestureRecognizer = nil;
    }
    
    if (_panGestureRecognizer) {
        if (_panGestureRecognizer.view) {
            [_panGestureRecognizer.view removeGestureRecognizer:_panGestureRecognizer];
        }
        _panGestureRecognizer = nil;
    }
    
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationWillResignActiveNotification object:nil];
}

#pragma mark - getter and setter implementation

- (id<LPDPhotoArrangeCVDataSource>)dataSource
{
    return (id<LPDPhotoArrangeCVDataSource>)self.collectionView.dataSource;
}

- (id<LPDPhotoArrangeCVFlowLayout>)delegate
{
    return (id<LPDPhotoArrangeCVFlowLayout>)self.collectionView.delegate;
}

#pragma mark - override UICollectionViewLayout methods

- (NSArray *)layoutAttributesForElementsInRect:(CGRect)rect
{
    NSArray * layoutAttributesForElementsInRect = [super layoutAttributesForElementsInRect:rect];
    
    for (UICollectionViewLayoutAttributes * layoutAttributes in layoutAttributesForElementsInRect) {
        
        if (layoutAttributes.representedElementCategory == UICollectionElementCategoryCell) {
            layoutAttributes.hidden = [layoutAttributes.indexPath isEqual:_movingItemIndexPath];
        }
    }
    return layoutAttributesForElementsInRect;
}

- (UICollectionViewLayoutAttributes *)layoutAttributesForItemAtIndexPath:(NSIndexPath *)indexPath
{
    UICollectionViewLayoutAttributes * layoutAttributes = [super layoutAttributesForItemAtIndexPath:indexPath];
    if (layoutAttributes.representedElementCategory == UICollectionElementCategoryCell) {
        layoutAttributes.hidden = [layoutAttributes.indexPath isEqual:_movingItemIndexPath];
    }
    return layoutAttributes;
}

#pragma mark - gesture

- (void)setPanGestureRecognizerEnable:(BOOL)panGestureRecognizerEnable
{
    _panGestureRecognizer.enabled = panGestureRecognizerEnable;
}

- (BOOL)panGestureRecognizerEnable
{
    return _panGestureRecognizer.enabled;
}

- (void)longPressGestureRecognizerTriggerd:(UILongPressGestureRecognizer *)longPress
{
    //记录上一次手势的位置
    static CGPoint startPoint;
    
    //选中的图片是否进入删除区域
    BOOL isIn = CGRectIntersectsRect([_beingMovedPromptView convertRect:_beingMovedPromptView.bounds toView:[UIApplication sharedApplication].keyWindow], [self.deleteRegionView convertRect:self.deleteRegionView.bounds toView:[UIApplication sharedApplication].keyWindow]);
    
    switch (longPress.state) {
        case UIGestureRecognizerStatePossible:
            break;
        case UIGestureRecognizerStateBegan:
        {
            if (_displayLink == nil) {
                _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(displayLinkTriggered:)];
                _displayLink.preferredFramesPerSecond = 6;
                [_displayLink addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
                
                _remainSecondsToBeginEditing = MIN_PRESS_TO_BEGIN_EDITING_DURATION;
            }
            
            _movingItemIndexPath = [self.collectionView indexPathForItemAtPoint:[longPress locationInView:self.collectionView]];
            if ([self.dataSource respondsToSelector:@selector(collectionView:canMoveItemAtIndexPath:)] && [self.dataSource collectionView:self.collectionView canMoveItemAtIndexPath:_movingItemIndexPath] == NO) {
                _movingItemIndexPath = nil;
                return;
            }
            
            if ([self.delegate respondsToSelector:@selector(collectionView:layout:willBeginDraggingItemAtIndexPath:)]) {
                [self.delegate collectionView:self.collectionView layout:self willBeginDraggingItemAtIndexPath:_movingItemIndexPath];
            }
            
            UICollectionViewCell *sourceCollectionViewCell = [self.collectionView cellForItemAtIndexPath:_movingItemIndexPath];
            LPDPhotoArrangeCell *sourceCell = (LPDPhotoArrangeCell *)sourceCollectionViewCell;
            
            //            _beingMovedPromptView = [[UIView alloc]initWithFrame:CGRectOffset(sourceCollectionViewCell.frame, -10, -10)];
            
            //创建选中图片的复制View
            _beingMovedPromptView = [[UIView alloc]initWithFrame:CGRectMake(self.collectionView.superview.superview.frame.origin.x + sourceCollectionViewCell.frame.origin.x + 10, self.collectionView.superview.superview.frame.origin.y + sourceCollectionViewCell.frame.origin.y + 10, sourceCollectionViewCell.frame.size.width, sourceCollectionViewCell.frame.size.height)];
            
            //            CGRect frameW = _beingMovedPromptView.frame;
            //            frameW.size.width += 20;
            //            _beingMovedPromptView.frame = frameW;
            //            CGRect frameH = _beingMovedPromptView.frame;
            //            frameH.size.height += 20;
            //            _beingMovedPromptView.frame = frameH;
            
            sourceCollectionViewCell.highlighted = YES;
            UIView * highlightedSnapshotView = [sourceCell snapshotView];
            highlightedSnapshotView.frame = _beingMovedPromptView.bounds;
            highlightedSnapshotView.alpha = 1;
            
            sourceCollectionViewCell.highlighted = NO;
            UIView * snapshotView = [sourceCell snapshotView];
            snapshotView.frame = _beingMovedPromptView.bounds;
            snapshotView.alpha = 0;
            
            [_beingMovedPromptView addSubview:snapshotView];
            [_beingMovedPromptView addSubview:highlightedSnapshotView];
            [self.collectionView.superview.superview.superview addSubview:_beingMovedPromptView];
            
            _sourceItemCollectionViewCellCenter = sourceCollectionViewCell.center;
            
            typeof(self) __weak weakSelf = self;
            [UIView animateWithDuration:0.2
                                  delay:0
                                options:UIViewAnimationOptionBeginFromCurrentState
                             animations:^{
                                 
                                 typeof(self) __strong strongSelf = weakSelf;
                                 if (strongSelf) {
                                     highlightedSnapshotView.alpha = 0;
                                     snapshotView.alpha = 1;
                                     _beingMovedPromptView.alpha = 0.8f;
                                 }
                             }
                             completion:^(BOOL finished) {
                                 
                                 typeof(self) __strong strongSelf = weakSelf;
                                 if (strongSelf) {
                                     [highlightedSnapshotView removeFromSuperview];
                                     
                                     if ([strongSelf.delegate respondsToSelector:@selector(collectionView:layout:didBeginDraggingItemAtIndexPath:)]) {
                                         [strongSelf.delegate collectionView:strongSelf.collectionView layout:strongSelf didBeginDraggingItemAtIndexPath:_movingItemIndexPath];
                                     }
                                 }
                             }];
            
            [self invalidateLayout];
            
            //重设起始位置
            startPoint = [longPress locationInView:self.collectionView.superview.superview.superview];
            //显示删除区域
            [self.deleteRegionView showInView:[UIApplication sharedApplication].keyWindow];
        }
            break;
        case UIGestureRecognizerStateChanged:
        {
            //开始拖动
            CGFloat tranX = [longPress locationOfTouch:0 inView:self.collectionView.superview.superview.superview].x  - startPoint.x;
            CGFloat tranY = [longPress locationOfTouch:0 inView:self.collectionView.superview.superview.superview].y - startPoint.y;
            //设置截图视图位置
            _beingMovedPromptView.center = CGPointApplyAffineTransform(_beingMovedPromptView.center, CGAffineTransformMakeTranslation(tranX, tranY));
            
            [self.deleteRegionView setStatusIsIn:isIn];
            //重设起始位置
            startPoint = [longPress locationOfTouch:0 inView:self.collectionView.superview.superview.superview];
        }
            break;
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        {
            
            [self.deleteRegionView hide];
            
            [_displayLink invalidate];
            _displayLink = nil;
            
            NSIndexPath * movingItemIndexPath = _movingItemIndexPath;
            
            if (isIn && _beingMovedPromptView) {
                //进入区域，准备删除
                //发送通知，删除选中图片
                [[NSNotificationCenter defaultCenter] postNotificationName:@"DeleteCellOfPhoto" object:self userInfo:@{@"IndexPath" : [NSString stringWithFormat:@"%zd", _movingItemIndexPath.row]}];
            }
            
            if (movingItemIndexPath) {
                if ([self.delegate respondsToSelector:@selector(collectionView:layout:willEndDraggingItemAtIndexPath:)]) {
                    [self.delegate collectionView:self.collectionView layout:self willEndDraggingItemAtIndexPath:movingItemIndexPath];
                }
                
                _movingItemIndexPath = nil;
                _sourceItemCollectionViewCellCenter = CGPointZero;
                
                UICollectionViewLayoutAttributes * movingItemCollectionViewLayoutAttributes = [self layoutAttributesForItemAtIndexPath:movingItemIndexPath];
                
                _longPressGestureRecognizer.enabled = NO;
                
                typeof(self) __weak weakSelf = self;
                [UIView animateWithDuration:0.2
                                      delay:0
                                    options:UIViewAnimationOptionBeginFromCurrentState
                                 animations:^{
                                     typeof(self) __strong strongSelf = weakSelf;
                                     if (strongSelf) {
                                         //                                         _beingMovedPromptView.center = movingItemCollectionViewLayoutAttributes.center;
                                     }
                                 }
                                 completion:^(BOOL finished) {
                                     
                                     _longPressGestureRecognizer.enabled = YES;
                                     
                                     typeof(self) __strong strongSelf = weakSelf;
                                     if (strongSelf) {
                                         [_beingMovedPromptView removeFromSuperview];
                                         _beingMovedPromptView = nil;
                                         [strongSelf invalidateLayout];
                                         
                                         if ([strongSelf.delegate respondsToSelector:@selector(collectionView:layout:didEndDraggingItemAtIndexPath:)]) {
                                             [strongSelf.delegate collectionView:strongSelf.collectionView layout:strongSelf didEndDraggingItemAtIndexPath:movingItemIndexPath];
                                         }
                                     }
                                 }];
            }
        }
            break;
        case UIGestureRecognizerStateFailed:
            break;
        default:
            break;
    }
}

- (void)panGestureRecognizerTriggerd:(UIPanGestureRecognizer *)pan
{
    switch (pan.state) {
        case UIGestureRecognizerStatePossible:
            break;
        case UIGestureRecognizerStateBegan:
        case UIGestureRecognizerStateChanged:
        {
            CGPoint panTranslation = [pan translationInView:self.collectionView.superview.superview.superview];
            _beingMovedPromptView.center = CGPointOffset(_sourceItemCollectionViewCellCenter, panTranslation.x, panTranslation.y);
            
            NSIndexPath * sourceIndexPath = _movingItemIndexPath;
            NSIndexPath * destinationIndexPath = [self.collectionView indexPathForItemAtPoint:_beingMovedPromptView.center];
            
            if ((destinationIndexPath == nil) || [destinationIndexPath isEqual:sourceIndexPath]) {
                return;
            }
            
            if ([self.dataSource respondsToSelector:@selector(collectionView:itemAtIndexPath:canMoveToIndexPath:)] && [self.dataSource collectionView:self.collectionView itemAtIndexPath:sourceIndexPath canMoveToIndexPath:destinationIndexPath] == NO) {
                return;
            }
            
            if ([self.dataSource respondsToSelector:@selector(collectionView:itemAtIndexPath:willMoveToIndexPath:)]) {
                [self.dataSource collectionView:self.collectionView itemAtIndexPath:sourceIndexPath willMoveToIndexPath:destinationIndexPath];
            }
            
            _movingItemIndexPath = destinationIndexPath;
            
            typeof(self) __weak weakSelf = self;
            [self.collectionView performBatchUpdates:^{
                typeof(self) __strong strongSelf = weakSelf;
                if (strongSelf) {
                    if (sourceIndexPath && destinationIndexPath) {
                        [strongSelf.collectionView deleteItemsAtIndexPaths:@[sourceIndexPath]];
                        [strongSelf.collectionView insertItemsAtIndexPaths:@[destinationIndexPath]];
                    }
                }
            } completion:^(BOOL finished) {
                typeof(self) __strong strongSelf = weakSelf;
                if ([strongSelf.dataSource respondsToSelector:@selector(collectionView:itemAtIndexPath:didMoveToIndexPath:)]) {
                    [strongSelf.dataSource collectionView:strongSelf.collectionView itemAtIndexPath:sourceIndexPath didMoveToIndexPath:destinationIndexPath];
                }
            }];
        }
            break;
        case UIGestureRecognizerStateEnded:
            break;
        case UIGestureRecognizerStateCancelled:
            break;
        case UIGestureRecognizerStateFailed:
            break;
        default:
            break;
    }
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer
{
    if ([_panGestureRecognizer isEqual:gestureRecognizer]) {
        return _movingItemIndexPath != nil;
    }
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer
{
    //  only _longPressGestureRecognizer and _panGestureRecognizer can recognize simultaneously
    if ([_longPressGestureRecognizer isEqual:gestureRecognizer]) {
        return [_panGestureRecognizer isEqual:otherGestureRecognizer];
    }
    if ([_panGestureRecognizer isEqual:gestureRecognizer]) {
        return [_longPressGestureRecognizer isEqual:otherGestureRecognizer];
    }
    return NO;
}

#pragma mark - displayLink

- (void)displayLinkTriggered:(CADisplayLink *)displayLink
{
    if (_remainSecondsToBeginEditing <= 0) {
        [_displayLink invalidate];
        _displayLink = nil;
    }
    
    _remainSecondsToBeginEditing = _remainSecondsToBeginEditing - 0.1;
}

#pragma mark - KVO and notification

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if ([keyPath isEqualToString:@stringify(collectionView)]) {
        if (self.collectionView) {
            [self addGestureRecognizers];
        }
        else {
            [self removeGestureRecognizers];
        }
    }
}

- (void)applicationWillResignActive:(NSNotification *)notificaiton
{
    _panGestureRecognizer.enabled = NO;
    _panGestureRecognizer.enabled = YES;
}

- (ZDeleteRegionView *)deleteRegionView{
    if (!_deleteRegionView) {
        _deleteRegionView = [[ZDeleteRegionView alloc] init];
        _deleteRegionView.alpha = 0.8f;
    }
    return _deleteRegionView;
}

@end

