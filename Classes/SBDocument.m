//
//  SBDocument.m
//  Subler
//
//  Created by Damiano Galassi on 29/01/09.
//  Copyright Damiano Galassi 2009 . All rights reserved.
//

#import "SBDocument.h"
#import "SBQueueController.h"
#import "SBQueueItem.h"
#import "SBFileImport.h"

#import "SBEmptyViewController.h"
#import "SBMovieViewController.h"
#import "SBVideoViewController.h"
#import "SBSoundViewController.h"
#import "SBChapterViewController.h"

#import "SBMetadataSearchController.h"
#import "SBArtworkSelector.h"

#import <MP42Foundation/MP42File.h>
#import <MP42Foundation/MP42Languages.h>
#import <MP42Foundation/MP42Utilities.h>

#define SublerTableViewDataType @"SublerTableViewDataType"

@interface SBDocument () <NSTableViewDelegate, MP42FileDelegate, SBFileImportDelegate, SBMetadataSearchControllerDelegate>

@property (nonatomic, retain) MP42File *mp4;

@end

@implementation SBDocument

@synthesize mp4 = _mp4File;

- (NSString *)windowNibName
{
    return @"SBDocument";
}

- (void)windowControllerDidLoadNib:(NSWindowController *)aController
{
    [super windowControllerDidLoadNib:aController];

    languages = [[[MP42Languages defaultManager] languages] retain];
    _optimize = NO;

    [self reloadPropertyView];
    [sendToQueue setImage:[NSImage imageNamed:NSImageNameShareTemplate]];

    [fileTracksTable registerForDraggedTypes:@[SublerTableViewDataType]];
    [documentWindow registerForDraggedTypes:@[NSFilenamesPboardType]];

    [optBar setUsesThreadedAnimation:NO];

    if ([[[NSUserDefaults standardUserDefaults] valueForKey:@"rememberWindowSize"] integerValue]) {
        [documentWindow setFrameAutosaveName:@"documentSave"];
        [documentWindow setFrameUsingName:@"documentSave"];
        [splitView setAutosaveName:@"splitViewSave"];
    }
}

- (instancetype)initWithMP4:(MP42File *)mp4File error:(NSError **)outError
{
    if (self = [super initWithType:@"Video-MPEG4" error:outError]) {
        self.mp4 = mp4File;
    }

    return self;
}

- (instancetype)initWithType:(NSString *)typeName error:(NSError **)outError
{
    if (self = [super initWithType:typeName error:outError]) {
        self.mp4 = [[[MP42File alloc] initWithDelegate:self] autorelease];
    }

    return self;
}


#pragma mark Read methods

+ (BOOL)canConcurrentlyReadDocumentsOfType:(NSString *)type
{
    return YES;
}

- (BOOL)isEntireFileLoaded
{
    return NO;
}

- (BOOL)readFromURL:(NSURL *)absoluteURL ofType:(NSString *)typeName error:(NSError **)outError
{
    self.mp4 = [[[MP42File alloc] initWithURL:absoluteURL delegate:self] autorelease];

    if (outError != NULL && !self.mp4) {
		*outError = [NSError errorWithDomain:NSOSStatusErrorDomain code:unimpErr userInfo:NULL];
        
        return NO;
	}

    return YES;
}

- (BOOL)revertToContentsOfURL:(NSURL *)absoluteURL ofType:(NSString *)typeName error:(NSError **)outError
{
    self.mp4 = [[[MP42File alloc] initWithURL:absoluteURL delegate:self] autorelease];

    [fileTracksTable reloadData];
    [self reloadPropertyView];
    [self updateChangeCount:NSChangeCleared];

    if (outError != NULL && !self.mp4) {
		*outError = [NSError errorWithDomain:NSOSStatusErrorDomain code:unimpErr userInfo:NULL];
        return NO;
	}
    return YES;
}

#pragma mark Save methods

- (BOOL)canAsynchronouslyWriteToURL:(NSURL *)url
                             ofType:(NSString *)typeName
                   forSaveOperation:(NSSaveOperationType)saveOperation
{
    return YES;
}

- (BOOL)writeSafelyToURL:(NSURL *)url ofType:(NSString *)typeName forSaveOperation:(NSSaveOperationType)saveOperation error:(NSError * _Nullable *)outError
{
    [self unblockUserInteraction];

    dispatch_sync(dispatch_get_main_queue(), ^{
        [optBar setIndeterminate:YES];
        [optBar startAnimation:self];
        [saveOperationName setStringValue:@"Saving…"];
        [NSApp beginSheet:savingWindow modalForWindow:documentWindow
            modalDelegate:nil didEndSelector:NULL contextInfo:nil];
    });

    IOPMAssertionID assertionID;
    // Enable sleep assertion
    CFStringRef reasonForActivity= CFSTR("Subler Save Operation");
    IOReturn io_success = IOPMAssertionCreateWithName(kIOPMAssertionTypeNoIdleSleep,
                                                      kIOPMAssertionLevelOn, reasonForActivity, &assertionID);
    BOOL result = NO;

    NSMutableDictionary<NSString *, NSNumber *> * attributes = [[NSMutableDictionary alloc] init];
    if ([[[NSUserDefaults standardUserDefaults] valueForKey:@"chaptersPreviewTrack"] boolValue]) {
        attributes[MP42GenerateChaptersPreviewTrack] = @YES;
    }
    if ([[[NSUserDefaults standardUserDefaults] valueForKey:@"SBOrganizeAlternateGroups"] boolValue]) {
        attributes[MP42OrganizeAlternateGroups] = @YES;
    }

    switch (saveOperation) {
        case NSSaveOperation:
            // movie file already exists, so we'll just update
            // the movie resource.
            result = [self.mp4 updateMP4FileWithAttributes:attributes error:outError];
            break;

        case NSSaveAsOperation:
            // movie does not exist, create a new one from scratch.
            if ([_64bit_data state]) { attributes[MP4264BitData] = @YES; }
            if ([_64bit_time state]) { attributes[MP4264BitTime] = @YES; }

            result = [self.mp4 writeToUrl:url withAttributes:attributes error:outError];
            break;

        default:
            NSAssert(NO, @"Unhandled save operation");
            break;
    }

    [attributes release];

    if (result && _optimize) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [saveOperationName setStringValue:@"Optimizing…"];
        });
        result = [self.mp4 optimize];
        _optimize = NO;
    }

    if (io_success == kIOReturnSuccess) {
        IOPMAssertionRelease(assertionID);
    }

    NSError *error = *outError;
    MP42File *reloadedFile = nil;

    if (result == YES) {
        reloadedFile = [[MP42File alloc] initWithURL:url delegate:self];
    }

    dispatch_sync(dispatch_get_main_queue(), ^{
        [optBar stopAnimation:self];
        [savingWindow orderOut:self];
        [NSApp endSheet:savingWindow];

        if (result == YES && error) {
            [self presentError:error
                modalForWindow:documentWindow
                        delegate:nil
            didPresentSelector:NULL
                    contextInfo:NULL];
        }

        if (reloadedFile) {
            self.mp4 = reloadedFile;
            [reloadedFile release];
        }

    });

    return result;
}

- (BOOL)prepareSavePanel:(NSSavePanel *)savePanel
{
    _currentSavePanel = savePanel;
    savePanel.extensionHidden = NO;
    savePanel.accessoryView = saveView;

    NSArray<NSString *> *formats = [self writableTypesForSaveOperation:NSSaveAsOperation];

    [fileFormat removeAllItems];
    for (NSString *format in formats) {
        [fileFormat addItemWithTitle:format];
    }

    [fileFormat selectItemAtIndex:[[[NSUserDefaults standardUserDefaults] valueForKey:@"defaultSaveFormat"] integerValue]];

    if ([[NSUserDefaults standardUserDefaults] valueForKey:@"SBSaveFormat"]) {
        _currentSavePanel.allowedFileTypes = @[[[NSUserDefaults standardUserDefaults] valueForKey:@"SBSaveFormat"]];
    }

    NSString *filename = nil;
    for (MP42Track *track in self.mp4.tracks) {
        if (track.sourceURL) {
            filename = track.sourceURL.lastPathComponent.stringByDeletingPathExtension;
            break;
        }
    }

    if (filename) {
        savePanel.nameFieldStringValue = filename;
    }

    if (self.mp4.dataSize > 4200000000) {
        [_64bit_data setState:NSOnState];
    }

    return YES;
}

- (IBAction)setSaveFormat:(NSPopUpButton *)sender
{
    NSString *requiredFileType = nil;
    NSInteger index = [sender indexOfSelectedItem];
    switch (index) {
        case 0:
            requiredFileType = MP42FileTypeM4V;
            break;
        case 1:
            requiredFileType = MP42FileTypeMP4;
            break;
        case 2:
            requiredFileType = MP42FileTypeM4A;
            break;
        case 3:
            requiredFileType = MP42FileTypeM4A;
            break;
        case 4:
            requiredFileType = MP42FileTypeM4R;
            break;
        default:
            requiredFileType = MP42FileTypeM4V;
            break;
    }

    [_currentSavePanel setAllowedFileTypes:@[requiredFileType]];
    [[NSUserDefaults standardUserDefaults] setObject:requiredFileType forKey:@"SBSaveFormat"];
}

- (IBAction)cancelSaveOperation:(id)sender
{
    [cancelSave setEnabled:NO];
    [self.mp4 cancel];
}

- (IBAction)saveAndOptimize:(id)sender
{
    _optimize = YES;
    [self saveDocument:sender];
}

- (IBAction)sendToExternalApp:(id)sender
{
    // Send to itunes after save.
    NSWorkspace *workspace = [NSWorkspace sharedWorkspace];
    NSString *appPath = [workspace fullPathForApplication:@"iTunes"];

    if (appPath) {
        [workspace openFile:self.fileURL.path withApplication:appPath];
    }
}

#pragma mark Interface validation

- (void)progressStatus:(CGFloat)progress
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [optBar setIndeterminate:NO];
        [optBar setDoubleValue:progress];
    });
}

- (BOOL)validateUserInterfaceItem:(id < NSValidatedUserInterfaceItem >)anItem
{
    SEL action = [anItem action];

    if (action == @selector(saveDocument:))
        if ([self isDocumentEdited])
            return YES;

    if (action == @selector(saveDocumentAs:))
        return YES;
    
    if (action == @selector(revertDocumentToSaved:))
        if ([self isDocumentEdited])
            return YES;

    if (action == @selector(saveAndOptimize:))
        if (![self isDocumentEdited] && [self.mp4 hasFileRepresentation])
            return YES;

    if (action == @selector(selectMetadataFile:))
        return YES;

    if (action == @selector(selectFile:))
        return YES;

    if (action == @selector(deleteTrack:))
        return YES;

    if (action == @selector(searchMetadata:))
        return YES;

    if (action == @selector(sendToQueue:))
        return YES;

    if (action == @selector(sendToExternalApp:))
        return YES;

    if (action == @selector(showTrackOffsetSheet:) && [fileTracksTable selectedRow] != -1)
        return YES;

    if (action == @selector(addChaptersEvery:))
        return YES;
    
    if (action == @selector(iTunesFriendlyTrackGroups:))
        return YES;

	if (action == @selector(export:) && [fileTracksTable selectedRow] != -1)
		if ([[self.mp4 trackAtIndex:[fileTracksTable selectedRow]] respondsToSelector:@selector(exportToURL:error:)] &&
            [[self.mp4 trackAtIndex:[fileTracksTable selectedRow]] muxed])
			return YES;

    return NO;
}

- (BOOL)validateToolbarItem:(NSToolbarItem *)toolbarItem
{
    if (toolbarItem == addTracks) {
        return YES;
    }

    if (toolbarItem == deleteTrack) {
        if ([fileTracksTable selectedRow] != -1 && [NSApp isActive])
                return YES;
    }

    if (toolbarItem == searchMetadata) {
        return YES;
    }

    if (toolbarItem == sendToQueue) {
        return YES;
    }

    return NO;
}

#pragma mark table datasource

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    return self.mp4.tracks.count;
}

- (id)tableView:(NSTableView *)tableView
objectValueForTableColumn:(NSTableColumn *)tableColumn 
             row:(NSInteger)rowIndex
{
    MP42Track *track = [self.mp4 trackAtIndex:rowIndex];

    if (!track)
        return nil;

    if ([tableColumn.identifier isEqualToString:@"trackId"])
        return (track.Id == 0) ? @"na" : [NSString stringWithFormat:@"%d", track.Id];

    if ([tableColumn.identifier isEqualToString:@"trackName"])
        return track.name;

    if ([tableColumn.identifier isEqualToString:@"trackInfo"])
        return track.formatSummary;

    if ([tableColumn.identifier isEqualToString:@"trackEnabled"])
        return @(track.isEnabled);

    if ([tableColumn.identifier isEqualToString:@"trackDuration"])
        return track.timeString;

    if ([tableColumn.identifier isEqualToString:@"trackLanguage"])
        return track.language;

    return nil;
}

- (void)tableView:(NSTableView *)tableView
   setObjectValue:(id)anObject
   forTableColumn:(NSTableColumn *)tableColumn
              row:(NSInteger)rowIndex
{
    MP42Track *track = [self.mp4 trackAtIndex:rowIndex];

    if ([tableColumn.identifier isEqualToString:@"trackLanguage"]) {
        if (![track.language isEqualToString:anObject]) {
            track.language = anObject;
            [self updateChangeCount:NSChangeDone];
        }
    }
    else if ([tableColumn.identifier isEqualToString:@"trackName"]) {
        if (![track.name isEqualToString:anObject]) {
            track.name = anObject;
            [self updateChangeCount:NSChangeDone];
        }
    }
    else if ([tableColumn.identifier isEqualToString:@"trackEnabled"]) {
        if (!(track.enabled  == [anObject integerValue])) {
            track.enabled = [anObject boolValue];
            [self updateChangeCount:NSChangeDone];
        }
    }
}

- (void)tableViewSelectionDidChange:(NSNotification *)aNotification
{
    [self reloadPropertyView];
}

- (void)reloadPropertyView
{
    if (propertyView.view != nil) {
        // remove the undo items from the dealloced view
        [[self undoManager] removeAllActionsWithTarget:propertyView];

        // remove the current view
		[propertyView.view removeFromSuperview];

        // remove the current view controller
        [propertyView release];
    }

    NSInteger row = [fileTracksTable selectedRow];

    id controller = nil;
    id track = (row != -1) ? [self.mp4 trackAtIndex:row] : nil;

    if (row == -1) {
        controller = [[SBMovieViewController alloc] initWithNibName:@"MovieView" bundle:nil];
        [controller setFile:self.mp4];
    } else if ([track isMemberOfClass:[MP42ChapterTrack class]]) {
        controller = [[SBChapterViewController alloc] initWithNibName:@"ChapterView" bundle:nil];
        [controller setTrack:track];
    } else if ([track isKindOfClass:[MP42VideoTrack class]]) {
        controller = [[SBVideoViewController alloc] initWithNibName:@"VideoView" bundle:nil];
        [controller setTrack:track];
        [controller setFile:self.mp4];
    } else if ([track isKindOfClass:[MP42AudioTrack class]]) {
        controller = [[SBSoundViewController alloc] initWithNibName:@"SoundView" bundle:nil];
        [controller setTrack:track];
        [controller setFile:self.mp4];
    } else {
        controller = [[SBEmptyViewController alloc] initWithNibName:@"EmptyView" bundle:nil];
    }

    propertyView = controller;

    // embed the current view to our host view
	[targetView addSubview:propertyView.view];
    [documentWindow recalculateKeyViewLoop];

	// make sure we automatically resize the controller's view to the current window size
	[[propertyView view] setFrame: [targetView bounds]];
    [[propertyView view] setAutoresizingMask:( NSViewWidthSizable | NSViewHeightSizable )];
}

- (BOOL)tableView:(NSTableView *)tv writeRowsWithIndexes:(NSIndexSet *)rowIndexes toPasteboard:(NSPasteboard *)pboard
{
    // Copy the row numbers to the pasteboard.
    if ([[self.mp4 trackAtIndex:[rowIndexes firstIndex]] muxed]) {
        return NO;
    }

    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:rowIndexes];
    [pboard declareTypes:@[SublerTableViewDataType] owner:self];
    [pboard setData:data forType:SublerTableViewDataType];
    return YES;
}

- (NSDragOperation)tableView:(NSTableView*)tv
                validateDrop:(id <NSDraggingInfo>)info
                 proposedRow:(NSInteger)row
       proposedDropOperation:(NSTableViewDropOperation)op
{
    NSUInteger count = self.mp4.tracks.count;
    if (op == NSTableViewDropAbove && row < count) {
        if (![[self.mp4 trackAtIndex:row] muxed]) {
            return NSDragOperationEvery;
        }
    } else if (op == NSTableViewDropAbove && row == count) {
        return NSDragOperationEvery;
    }

    return NSDragOperationNone;
}

- (BOOL)tableView:(NSTableView *)aTableView acceptDrop:(id <NSDraggingInfo>)info
              row:(NSInteger)row dropOperation:(NSTableViewDropOperation)operation
{
    NSPasteboard* pboard = [info draggingPasteboard];
    NSData* rowData = [pboard dataForType:SublerTableViewDataType];
    NSIndexSet* rowIndexes = [NSKeyedUnarchiver unarchiveObjectWithData:rowData];
    NSInteger dragRow = [rowIndexes firstIndex];
    
    [self.mp4 moveTrackAtIndex:dragRow toIndex:row];
    [fileTracksTable reloadData];
    return YES;
}

- (BOOL)canDragRowsWithIndexes:(NSIndexSet *)rowIndexes atPoint:(NSPoint)mouseDownPoint
{
    return YES;
}

/* NSComboBoxCell dataSource */

- (NSInteger)numberOfItemsInComboBoxCell:(NSComboBoxCell *)comboBoxCell
{
    return [languages count];
}

- (id)comboBoxCell:(NSComboBoxCell *)comboBoxCell objectValueForItemAtIndex:(NSInteger)index {
    return [languages objectAtIndex:index];
}

- (NSUInteger)comboBoxCell:(NSComboBoxCell *)comboBoxCell indexOfItemWithStringValue:(NSString *)string {
    return [languages indexOfObject: string];
}

#pragma mark Various things

- (void)didEndSheet:(NSWindow *)sheet returnCode:(NSInteger)returnCode contextInfo:(void *)contextInfo
{
    [[importWindow window] orderOut:nil];
    [importWindow autorelease], importWindow = nil;

    [fileTracksTable reloadData];
    [self reloadPropertyView];
}

- (IBAction)sendToQueue:(id)sender
{
    SBQueueController *queue =  [SBQueueController sharedManager];
    if ([self.mp4 hasFileRepresentation]) {
        SBQueueItem *item = [SBQueueItem itemWithMP4:self.mp4];
        [queue addItem:item];
        [self close];
    } else {
        NSSavePanel *panel = [NSSavePanel savePanel];
        [self prepareSavePanel:panel];

        [panel setPrompt:@"Send To Queue"];

        [panel beginSheetModalForWindow:documentWindow completionHandler:^(NSInteger result) {
            if (result == NSFileHandlingPanelOKButton) {
                NSMutableDictionary *attributes = [[NSMutableDictionary alloc] init];

                if ([_64bit_data state]) [attributes setObject:@YES forKey:MP4264BitData];
                if ([_64bit_time state]) [attributes setObject:@YES forKey:MP4264BitTime];
                if ([[[NSUserDefaults standardUserDefaults] valueForKey:@"chaptersPreviewTrack"] boolValue]) {
                    [attributes setObject:@YES forKey:MP42GenerateChaptersPreviewTrack];
                }

                SBQueueItem *item = [SBQueueItem itemWithMP4:self.mp4 destinationURL:panel.URL attributes:attributes];
                [queue addItem:item];

                [attributes release];
                [self close];
            }
        }];
    }
}

- (IBAction)searchMetadata:(id)sender
{
    NSString *filename = nil;
    for (MP42Track *track in self.mp4.tracks) {
        if (track.sourceURL) {
            filename = [track.sourceURL lastPathComponent];
            break;
        }
    }

    importWindow = [[SBMetadataSearchController alloc] initWithDelegate:self searchString:filename];

    [NSApp beginSheet:[importWindow window]
       modalForWindow:documentWindow
        modalDelegate:self
       didEndSelector:@selector(didEndSheet:returnCode:contextInfo:)
          contextInfo:nil];
}

- (void)metadataImportDone:(MP42Metadata *)metadataToBeImported
{
    [metadataToBeImported retain];
    if (metadataToBeImported) {
        [self.mp4.metadata mergeMetadata:metadataToBeImported];

        for (MP42Track *track in self.mp4.tracks)
            if ([track isKindOfClass:[MP42VideoTrack class]]) {
                MP42VideoTrack *videoTrack = (MP42VideoTrack *)track;
                int hdVideo = isHdVideo((uint64_t)videoTrack.trackWidth, (uint64_t)videoTrack.trackHeight);

                if (hdVideo) {
                    self.mp4.metadata[@"HD Video"] = @(hdVideo);
                }
            }
        [self updateChangeCount:NSChangeDone];
    }

    [metadataToBeImported release];
}

- (IBAction)showTrackOffsetSheet:(id)sender
{
    [offset setStringValue:[NSString stringWithFormat:@"%lld",
                            [[[self.mp4 tracks] objectAtIndex:[fileTracksTable selectedRow]] startOffset]]];

    [NSApp beginSheet:offsetWindow modalForWindow:documentWindow
        modalDelegate:nil didEndSelector:NULL contextInfo:nil];
}

- (IBAction)setTrackOffset:(id)sender
{
    MP42Track *selectedTrack = [[self.mp4 tracks] objectAtIndex:[fileTracksTable selectedRow]];
    [selectedTrack setStartOffset:[offset integerValue]];

    [self updateChangeCount:NSChangeDone];

    [NSApp endSheet: offsetWindow];
    [offsetWindow orderOut:self];
}

- (IBAction)closeOffsetSheet:(id)sender
{
    [NSApp endSheet: offsetWindow];
    [offsetWindow orderOut:self];
}

- (IBAction)deleteTrack:(id)sender
{
    if ([fileTracksTable selectedRow] == -1  || [fileTracksTable editedRow] != -1) {
        return;
    }

    [self.mp4 removeTrackAtIndex:[fileTracksTable selectedRow]];

    [self.mp4 organizeAlternateGroups];

    [fileTracksTable reloadData];
    [self reloadPropertyView];
    [self updateChangeCount:NSChangeDone];
}

// Import tracks from file

- (void)addChapterTrack:(NSURL *)fileURL
{
    [self.mp4 addTrack:[MP42ChapterTrack chapterTrackFromFile:fileURL]];

    [fileTracksTable reloadData];
    [self reloadPropertyView];
    [self updateChangeCount:NSChangeDone];
}

- (void)updateChapters:(MP42ChapterTrack *)chapters fromCSVFile:(NSURL *)URL
{
    NSError *error;
    if ([chapters updateFromCSVFile:URL error:&error]) {
        [self reloadPropertyView];
        [self updateChangeCount:NSChangeDone];
    }
    else {
        [self presentError:error modalForWindow:documentWindow delegate:nil didPresentSelector:NULL contextInfo:nil];
    }
}

- (IBAction)selectFile:(id)sender
{
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowsMultipleSelection = NO;
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;

    MP42ChapterTrack *chapters = self.mp4.chapters;
    if (chapters) {
        panel.allowedFileTypes = [supportedFileFormat() arrayByAddingObject:@"csv"];
    }
    else {
        panel.allowedFileTypes = supportedFileFormat();
    }

    [panel beginSheetModalForWindow:documentWindow completionHandler:^(NSInteger result) {
        if (result == NSFileHandlingPanelOKButton) {
            NSString *fileExtension = panel.URLs.firstObject.pathExtension;

            if ([fileExtension caseInsensitiveCompare: @"txt"] == NSOrderedSame) {
                [self addChapterTrack:[panel.URLs objectAtIndex: 0]];
            }
            else if ([fileExtension caseInsensitiveCompare: @"csv"] == NSOrderedSame) {
                [self updateChapters:chapters fromCSVFile:panel.URLs.firstObject];
            }
            else {
                [self performSelectorOnMainThread:@selector(showImportSheet:)
                                       withObject:panel.URLs waitUntilDone: NO];
            }
        }
    }];
}

- (void)showImportSheet:(NSArray<NSURL *> *)fileURLs
{
    NSError *error = nil;

    importWindow = [[SBFileImport alloc] initWithURLs:fileURLs delegate:self error:&error];

    if (importWindow) {
		if ([importWindow onlyContainsSubtitleTracks]) {
			[importWindow addTracks:self];
			[self didEndSheet:nil returnCode:NSOKButton contextInfo:nil];
		}
        else { // show the dialog
			[NSApp beginSheet:[importWindow window] modalForWindow:documentWindow
				modalDelegate:self didEndSelector:@selector(didEndSheet:returnCode:contextInfo:) contextInfo:NULL];
		}
    }
    else if (error) {
            [self presentError:error modalForWindow:documentWindow delegate:nil didPresentSelector:NULL contextInfo:nil];
    }
}

- (void)importDoneWithTracks:(NSArray<MP42Track *> *)tracksToBeImported andMetadata:(MP42Metadata *)metadata
{
    if (tracksToBeImported) {
        for (MP42Track *track in tracksToBeImported) {
            [self.mp4 addTrack:track];
        }

        [self updateChangeCount:NSChangeDone];

        if ([[[NSUserDefaults standardUserDefaults] valueForKey:@"SBOrganizeAlternateGroups"] boolValue]) {
            [self.mp4 organizeAlternateGroups];
        }
    }

    if (metadata) {
        [self.mp4.metadata mergeMetadata:metadata];
        [self updateChangeCount:NSChangeDone];
    }
}

- (void)addMetadata:(NSURL *)URL
{
    if ([[URL pathExtension] isEqualToString:@"xml"] || [[URL pathExtension] isEqualToString:@"nfo"]) {
        MP42Metadata *xmlMetadata = [[MP42Metadata alloc] initWithFileURL:URL];
        [self.mp4.metadata mergeMetadata:xmlMetadata];
        [xmlMetadata release];
    }
    else {
        MP42File *file = nil;
        if ((file = [[MP42File alloc] initWithURL:URL delegate:self])) {
            [self.mp4.metadata mergeMetadata:file.metadata];
            [file release];
        }
    }

    [self reloadPropertyView];
    [self updateChangeCount:NSChangeDone];
}

- (IBAction)selectMetadataFile:(id)sender
{
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowsMultipleSelection = NO;
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowedFileTypes = @[@"mp4", @"m4v", @"m4a", @"xml", @"nfo"];
    
    [panel beginSheetModalForWindow:documentWindow completionHandler:^(NSInteger result) {
        if (result == NSFileHandlingPanelOKButton) {
            [self addMetadata:[panel URL]];
        }
    }];
}

- (IBAction)export:(id)sender
{
    NSInteger row = [fileTracksTable selectedRow];
    NSSavePanel * panel = [NSSavePanel savePanel];
    NSString *filename = [[[[self fileURL] path] stringByDeletingPathExtension] lastPathComponent];

    if (row != -1 && [[self.mp4 trackAtIndex:row] isKindOfClass:[MP42SubtitleTrack class]]) {
        panel.allowedFileTypes = @[@"srt"];
        filename = [filename stringByAppendingFormat:@".%@", [[self.mp4 trackAtIndex:row] language]];
    }
	else if (row != -1 ) {
        filename = [filename stringByAppendingString:@" - Chapters"];
        panel.allowedFileTypes = @[@"txt"];
    }

    [panel setCanSelectHiddenExtension: YES];
    [panel setNameFieldStringValue:filename];
    
    [panel beginSheetModalForWindow:documentWindow completionHandler:^(NSInteger result) {
        if (result == NSFileHandlingPanelOKButton) {
            id track = [self.mp4 trackAtIndex:[fileTracksTable selectedRow]];
            
            if (![track exportToURL: [panel URL] error: nil]) {
                NSAlert * alert = [[NSAlert alloc] init];
                [alert addButtonWithTitle: NSLocalizedString(@"OK", "Export alert panel -> button")];
                [alert setMessageText: NSLocalizedString(@"File Could Not Be Saved", "Export alert panel -> title")];
                [alert setInformativeText: [NSString stringWithFormat:
                                            NSLocalizedString(@"There was a problem creating the file \"%@\".",
                                                              "Export alert panel -> message"), [[[panel URL] path] lastPathComponent]]];
                [alert setAlertStyle: NSWarningAlertStyle];
                
                [alert runModal];
                [alert release];
            }

        }
    }];
}

- (IBAction)addChaptersEvery:(id)sender
{
    MP42ChapterTrack *chapterTrack = self.mp4.chapters;
    NSInteger minutes = [sender tag] * 60 * 1000;

    if (!chapterTrack) {
        chapterTrack = [[MP42ChapterTrack alloc] init];
        [chapterTrack setDuration:self.mp4.duration];
        [self.mp4 addTrack:chapterTrack];
        [chapterTrack release];
    }

    if (minutes) {
        for (NSInteger i = 0, y = 1; i < self.mp4.duration; i += minutes, y++) {
            [chapterTrack addChapter:[NSString stringWithFormat:@"Chapter %ld", (long)y]
                            duration:i];
        }
    }
    else {
        [chapterTrack addChapter:@"Chapter 1"
                        duration:self.mp4.duration];
    }

    [fileTracksTable reloadData];
    [self reloadPropertyView];
    [self updateChangeCount:NSChangeDone];
}

- (IBAction)iTunesFriendlyTrackGroups:(id)sender
{
    [self.mp4 organizeAlternateGroups];
    [fileTracksTable reloadData];
    [self reloadPropertyView];
    [self updateChangeCount:NSChangeDone];
}

// Drag & Drop

- (NSDragOperation)draggingEntered:(id <NSDraggingInfo>)sender {
    NSPasteboard *pboard = [sender draggingPasteboard];
    NSDragOperation sourceDragMask = [sender draggingSourceOperationMask];

    if ([pboard.types containsObject:NSFilenamesPboardType]) {
         if (sourceDragMask & NSDragOperationCopy) {
            return NSDragOperationCopy;
         }
    }
    return NSDragOperationNone;
}

- (BOOL)performDragOperation:(id <NSDraggingInfo>)sender {
    NSPasteboard *pboard = [sender draggingPasteboard];

    if ( [[pboard types] containsObject:NSURLPboardType] ) {
        NSArray *items = [pboard readObjectsForClasses:@[[NSURL class]] options:nil];
        NSMutableArray<NSURL *> *supportedItems = [[[NSMutableArray alloc] init] autorelease];

        for (NSURL *url in items) {
            NSString *pathExtension = url.pathExtension;
            if ([pathExtension caseInsensitiveCompare: @"txt"] == NSOrderedSame) {
                [self addChapterTrack:url];
            }
            else if ([pathExtension caseInsensitiveCompare: @"xml"] == NSOrderedSame ||
                     [pathExtension caseInsensitiveCompare: @"nfo"] == NSOrderedSame) {
                [self addMetadata:url];
            }
            else if (isFileFormatSupported(pathExtension)) {
                [supportedItems addObject:url];
            }
        }
        
        if (supportedItems.count) {
            [self showImportSheet:supportedItems];
        }

        return YES;
    }

    return NO;
}

- (void)dealloc
{
    [fileTracksTable setDelegate:nil];
    [fileTracksTable setDataSource:nil];

    [propertyView release];
    propertyView = nil;

    [languages release];
    languages = nil;

    [_mp4File release];
    _mp4File = nil;

    [super dealloc];
}

@end
