//
//  TLMMainWindowController.m
//  TeX Live Manager
//
//  Created by Adam Maxwell on 12/6/08.
/*
 This software is Copyright (c) 2008-2009
 Adam Maxwell. All rights reserved.
 
 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions
 are met:
 
 - Redistributions of source code must retain the above copyright
 notice, this list of conditions and the following disclaimer.
 
 - Redistributions in binary form must reproduce the above copyright
 notice, this list of conditions and the following disclaimer in
 the documentation and/or other materials provided with the
 distribution.
 
 - Neither the name of Adam Maxwell nor the names of any
 contributors may be used to endorse or promote products derived
 from this software without specific prior written permission.
 
 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
 LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "TLMMainWindowController.h"
#import "TLMPackage.h"
#import "TLMPackageListDataSource.h"
#import "TLMUpdateListDataSource.h"

#import "TLMListUpdatesOperation.h"
#import "TLMUpdateOperation.h"
#import "TLMInfraUpdateOperation.h"
#import "TLMPapersizeOperation.h"
#import "TLMAuthorizedOperation.h"
#import "TLMListOperation.h"
#import "TLMRemoveOperation.h"
#import "TLMInstallOperation.h"

#import "TLMSplitView.h"
#import "TLMStatusWindow.h"
#import "TLMInfoController.h"
#import "TLMPreferenceController.h"
#import "TLMLogServer.h"
#import "TLMAppController.h"
#import "TLMPapersizeController.h"
#import "TLMTabView.h"
#import "TLMReadWriteOperationQueue.h"

static char _TLMOperationQueueOperationContext;

@implementation TLMMainWindowController

@synthesize _progressIndicator;
@synthesize _hostnameView;
@synthesize _splitView;
@synthesize _logDataSource;
@synthesize _packageListDataSource;
@synthesize _tabView;
@synthesize _statusBarView;
@synthesize _updateListDataSource;
@synthesize infrastructureNeedsUpdate = _updateInfrastructure;

- (id)init
{
    return [self initWithWindowNibName:[self windowNibName]];
}

- (id)initWithWindowNibName:(NSString *)windowNibName
{
    self = [super initWithWindowNibName:windowNibName];
    if (self) {
        TLMReadWriteOperationQueue *queue = [TLMReadWriteOperationQueue defaultQueue];
        [queue addObserver:self forKeyPath:@"operationCount" options:0 context:&_TLMOperationQueueOperationContext];
        _lastTextViewHeight = 0.0;
        _updateInfrastructure = NO;
        _operationCount = 0;
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [[TLMReadWriteOperationQueue defaultQueue] removeObserver:self forKeyPath:@"operationCount"];
    
    [_tabView setDelegate:nil];
    [_tabView release];
    
    [_splitView setDelegate:nil];
    [_splitView release];
    
    [_statusBarView release];
    [_hostnameView release];
    
    [_progressIndicator release];
    [_logDataSource release];
    [_packageListDataSource release];
    [_updateListDataSource release];
    
    [super dealloc];
}

- (void)awakeFromNib
{
    [[self window] setTitle:[[NSBundle mainBundle] objectForInfoDictionaryKey:(id)kCFBundleNameKey]];

    // set delegate before adding tabs, so the datasource gets inserted properly in the responder chain
    _currentListDataSource = _updateListDataSource;
    [_tabView setDelegate:self];
    [_tabView addTabNamed:NSLocalizedString(@"Manage Updates", @"tab title") withView:[[_updateListDataSource tableView]  enclosingScrollView]];
    [_tabView addTabNamed:NSLocalizedString(@"Manage Packages", @"tab title") withView:[[_packageListDataSource outlineView] enclosingScrollView]];
    
    // 10.5 release notes say this is enabled by default, but it returns NO
    [_progressIndicator setUsesThreadedAnimation:YES];
}

- (void)windowDidLoad
{
    [super windowDidLoad];
    
    // may as well populate the list immediately; by now we should have the window to display a warning sheet
    [self refreshUpdatedPackageList];
    
    // checkbox in IB doesn't work?
    [[[self window] toolbar] setAutosavesConfiguration:YES];
}

- (NSString *)windowNibName { return @"MainWindow"; }

- (void)_setOperationCountAsNumber:(NSNumber *)count
{
    NSParameterAssert([NSThread isMainThread]);
    
    NSUInteger newCount = [count unsignedIntegerValue];
    if (_operationCount != newCount) {
        
        // previous count was zero, so spinner is currently stopped
        if (0 == _operationCount) {
            [_progressIndicator startAnimation:self];
        }
        // previous count != 0, so spinner is currently animating
        else if (0 == newCount) {
            [_progressIndicator stopAnimation:self];
        }
        
        // validation depends on this value
        _operationCount = newCount;
        
        // can either do this or post a custom event...
        [[[self window] toolbar] validateVisibleItems];
    }
}

// NB: this will arrive on the queue's thread, at least under some conditions!
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if (context == &_TLMOperationQueueOperationContext) {
        /*
         NSOperationQueue + KVO sucks: calling performSelectorOnMainThread:withObject:waitUntilDone: 
         with waitUntilDone:YES will cause a deadlock if the main thread is currently in a callout to -[NSOperationQueue operations].
         What good is KVO on a non-main thread anyway?  That makes it useless for bindings, and KVO is a pain in the ass to use
         vs. something like NSNotification.  Grrr.
         */
        NSNumber *count = [NSNumber numberWithUnsignedInteger:[[TLMReadWriteOperationQueue defaultQueue] operationCount]];
        [self performSelectorOnMainThread:@selector(_setOperationCountAsNumber:) withObject:count waitUntilDone:NO];
    }
    else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

// tried validating toolbar items using bindings to queue.operations.@count but the queue sends KVO notifications on its own thread
- (BOOL)validateUserInterfaceItem:(id <NSValidatedUserInterfaceItem>)anItem;
{
    SEL action = [anItem action];
    if (@selector(cancelAllOperations:) == action)
        return _operationCount > 0;
    else
        return YES;
}

- (BOOL)windowShouldClose:(id)sender;
{
    BOOL shouldClose = YES;
    if ([[TLMReadWriteOperationQueue defaultQueue] isWriting]) {
        NSAlert *alert = [[NSAlert new] autorelease];
        [alert setMessageText:NSLocalizedString(@"Installation in progress!", @"alert title")];
        [alert setAlertStyle:NSCriticalAlertStyle];
        [alert setInformativeText:NSLocalizedString(@"If you close the window, the installation process may leave your TeX installation in an unknown state.  You can ignore this warning and close the window, or wait until the installation finishes.", @"alert message text")];
        [alert addButtonWithTitle:NSLocalizedString(@"Wait", @"button title")];
        [alert addButtonWithTitle:NSLocalizedString(@"Ignore", @"button title")];
        
        NSInteger rv = [alert runModal];
        if (NSAlertFirstButtonReturn == rv)
            shouldClose = NO;
    }
    return shouldClose;
}

#pragma mark Interface updates

/*
 Cover for <TLMListDataSource> lastUpdateURL that ensures the URL is non-nil.  
 The original tlmgr (August 2008 MacTeX) doesn't print the URL on the first line of output, 
 and we die with various assertion failures if the URL is nil.  Parsing logs a diagnostic
 in this case, as well, since this breaks some functionality.
 */
- (NSURL *)_lastUpdateURL
{
    NSURL *aURL = [_currentListDataSource lastUpdateURL];
    if (nil == aURL)
        aURL = [[TLMPreferenceController sharedPreferenceController] defaultServerURL];
    NSParameterAssert(aURL);
    return aURL;
}

- (void)_updateURLView
{
    NSURL *aURL = [self _lastUpdateURL];
    NSTextStorage *ts = [_hostnameView textStorage];
    [[ts mutableString] setString:[aURL absoluteString]];
    [ts addAttribute:NSFontAttributeName value:[NSFont labelFontOfSize:0] range:NSMakeRange(0, [ts length])];
    [ts addAttribute:NSLinkAttributeName value:aURL range:NSMakeRange(0, [ts length])];
    [ts addAttributes:[_hostnameView linkTextAttributes] range:NSMakeRange(0, [ts length])];
}

// pass nil for status to clear the view and remove it
- (void)_displayStatusString:(NSString *)statusString
{
    if (statusString) {
        // may currently be a window, so get rid of it
        [[_currentListDataSource statusWindow] fadeOutAndRemove:YES];
        
        // child window is one shot
        [_currentListDataSource setStatusWindow:[TLMStatusWindow windowWithStatusString:statusString frameFromView:_tabView]];
        [[self window] addChildWindow:[_currentListDataSource statusWindow] ordered:NSWindowAbove];
        [[_currentListDataSource statusWindow] fadeIn];
    }
    else if ([_currentListDataSource statusWindow]) {
        NSParameterAssert([[[self window] childWindows] containsObject:[_currentListDataSource statusWindow]]);
        [[_currentListDataSource statusWindow] fadeOutAndRemove:YES];
        [_currentListDataSource setStatusWindow:nil];
    }
}    

- (void)_removeDataSourceFromResponderChain:(id)dataSource
{
    NSResponder *next = [self nextResponder];
    if ([next isEqual:_updateListDataSource] || [next isEqual:_packageListDataSource]) {
        [self setNextResponder:[next nextResponder]];
        [next setNextResponder:nil];
    }
}

- (void)_insertDataSourceInResponderChain:(id)dataSource
{
    NSResponder *next = [self nextResponder];
    NSParameterAssert([next isEqual:_updateListDataSource] == NO);
    NSParameterAssert([next isEqual:_packageListDataSource] == NO);
    
    [self setNextResponder:dataSource];
    [dataSource setNextResponder:next];
}

- (void)tabView:(TLMTabView *)tabView didSelectViewAtIndex:(NSUInteger)anIndex;
{
    // clear the status overlay, if any
    [[_currentListDataSource statusWindow] fadeOutAndRemove:NO];
    
    switch (anIndex) {
        case 0:
            
            [self _removeDataSourceFromResponderChain:_packageListDataSource];
            [self _insertDataSourceInResponderChain:_updateListDataSource];   
            _currentListDataSource = _updateListDataSource;
            [self _updateURLView];
            [[_currentListDataSource statusWindow] fadeIn];

            if ([[_updateListDataSource allPackages] count])
                [_updateListDataSource search:nil];
            break;
        case 1:
            
            [self _removeDataSourceFromResponderChain:_updateListDataSource];
            [self _insertDataSourceInResponderChain:_packageListDataSource];   
            _currentListDataSource = _packageListDataSource;
            [self _updateURLView];
            [[_currentListDataSource statusWindow] fadeIn];

            // we load the update list on launch, so load this one on first access of the tab

            if ([[_packageListDataSource packageNodes] count])
                [_packageListDataSource search:nil];
            else if ([_packageListDataSource isRefreshing] == NO)
                [self refreshFullPackageList];

            break;
        default:
            break;
    }
}

// implementation from BibDesk's BDSKEditor
- (void)splitView:(TLMSplitView *)splitView doubleClickedDividerAt:(NSUInteger)subviewIndex;
{
    NSView *tableView = [[splitView subviews] objectAtIndex:0];
    NSView *textView = [[splitView subviews] objectAtIndex:1];
    NSRect tableFrame = [tableView frame];
    NSRect textViewFrame = [textView frame];
    
    // not sure what the criteria for isSubviewCollapsed, but it doesn't work
    if(NSHeight(textViewFrame) > 0.0){ 
        // save the current height
        _lastTextViewHeight = NSHeight(textViewFrame);
        tableFrame.size.height += _lastTextViewHeight;
        textViewFrame.size.height = 0.0;
    } else {
        // previously collapsed, so pick a reasonable value to start
        if(_lastTextViewHeight <= 0.0)
            _lastTextViewHeight = 150.0; 
        textViewFrame.size.height = _lastTextViewHeight;
        tableFrame.size.height = NSHeight([splitView frame]) - _lastTextViewHeight - [splitView dividerThickness];
        if (NSHeight(tableFrame) < 0.0) {
            tableFrame.size.height = 0.0;
            textViewFrame.size.height = NSHeight([splitView frame]) - [splitView dividerThickness];
            _lastTextViewHeight = NSHeight(textViewFrame);
        }
    }
    [tableView setFrame:tableFrame];
    [textView setFrame:textViewFrame];
    [splitView adjustSubviews];
    // fix for NSSplitView bug, which doesn't send this in adjustSubviews
    [[NSNotificationCenter defaultCenter] postNotificationName:NSSplitViewDidResizeSubviewsNotification object:splitView];
}

#pragma mark -
#pragma mark Operations

- (BOOL)_checkCommandPathAndWarn:(BOOL)displayWarning
{
    NSString *cmdPath = [[TLMPreferenceController sharedPreferenceController] tlmgrAbsolutePath];
    BOOL exists = [[NSFileManager defaultManager] isExecutableFileAtPath:cmdPath];
    
    if (NO == exists) {
        TLMLog(__func__, @"tlmgr not found at \"%@\"", cmdPath);
        if (displayWarning) {
            NSAlert *alert = [[NSAlert new] autorelease];
            [alert setMessageText:NSLocalizedString(@"TeX installation not found.", @"alert sheet title")];
            [alert setInformativeText:[NSString stringWithFormat:NSLocalizedString(@"The tlmgr tool does not exist at %@.  Please set the correct location in preferences or install TeX Live.", @"alert message text"), cmdPath]];
            [alert beginSheetModalForWindow:[self window] modalDelegate:nil didEndSelector:NULL contextInfo:NULL];
        }
    }
    
    return exists;
}

- (void)_addOperation:(TLMOperation *)op selector:(SEL)sel
{
    if (op && [self _checkCommandPathAndWarn:YES]) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:sel name:TLMOperationFinishedNotification object:op];
        [[TLMReadWriteOperationQueue defaultQueue] addOperation:op];
    }
}

- (void)_updateAllPackages
{
    TLMUpdateOperation *op = nil;
    NSURL *currentURL = [self _lastUpdateURL];
    if (_updateInfrastructure) {
        op = [[TLMInfraUpdateOperation alloc] initWithLocation:currentURL];
        TLMLog(__func__, @"Beginning infrastructure update from %@", [currentURL absoluteString]);
    }
    else {
        op = [[TLMUpdateOperation alloc] initWithPackageNames:nil location:currentURL];
        TLMLog(__func__, @"Beginning update of all packages from %@", [currentURL absoluteString]);
    }
    [self _addOperation:op selector:@selector(_handleUpdateFinishedNotification:)];
    [op release];
}

- (void)_handleListUpdatesFinishedNotification:(NSNotification *)aNote
{
    NSParameterAssert([NSThread isMainThread]);
    TLMListUpdatesOperation *op = [aNote object];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:TLMOperationFinishedNotification object:op];
    
    NSArray *allPackages = [op packages];

    // Karl sez these are the packages that the next version of tlmgr will require you to install before installing anything else
    // note that a slow-to-update mirror may have a stale version, so check needsUpdate as well
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"(name IN { 'bin-texlive', 'texlive.infra' }) AND (needsUpdate == YES)"];
    NSArray *packages = [allPackages filteredArrayUsingPredicate:predicate];
    
    if ([packages count]) {
        _updateInfrastructure = YES;
        // log for debugging, then display an alert so the user has some idea of what's going on...
        TLMLog(__func__, @"Critical updates detected: %@", [packages valueForKey:@"name"]);
        NSAlert *alert = [[NSAlert new] autorelease];
        [alert setMessageText:NSLocalizedString(@"Critical updates available.", @"alert title")];
        [alert setInformativeText:[NSString stringWithFormat:NSLocalizedString(@"%d packages are available for update, but the TeX Live installer packages listed here must be updated first.  Update now?", @"alert message text"), [[op packages] count]]];
        [alert addButtonWithTitle:NSLocalizedString(@"Update", @"button title")];
        [alert addButtonWithTitle:NSLocalizedString(@"Cancel", @"button title")];
        [alert beginSheetModalForWindow:[self window]
                          modalDelegate:self 
                         didEndSelector:@selector(infrastructureAlertDidEnd:returnCode:contextInfo:) 
                            contextInfo:NULL];
    }
    else {
        _updateInfrastructure = NO;
        packages = allPackages;
    }
    
    [_updateListDataSource setAllPackages:packages];
    [_updateListDataSource setRefreshing:NO];
    [_updateListDataSource setLastUpdateURL:[op updateURL]];
    [self _updateURLView];
    
    NSString *statusString = nil;
    
    if ([op isCancelled])
        statusString = NSLocalizedString(@"Listing Cancelled", @"main window status string");
    else if ([op failed])
        statusString = NSLocalizedString(@"Listing Failed", @"main window status string");
    else if ([packages count] == 0)
        statusString = NSLocalizedString(@"No Updates Available", @"main window status string");
    
    [self _displayStatusString:statusString];
}

- (void)_refreshUpdatedPackageListFromLocation:(NSURL *)location
{
    [self _displayStatusString:nil];
    // disable refresh action for this view
    [_updateListDataSource setRefreshing:YES];
    TLMListUpdatesOperation *op = [[TLMListUpdatesOperation alloc] initWithLocation:location];
    [self _addOperation:op selector:@selector(_handleListUpdatesFinishedNotification:)];
    [op release];
    TLMLog(__func__, @"Refreshing list of updated packages%C", 0x2026);
}

- (void)_handleUpdateFinishedNotification:(NSNotification *)aNote
{
    NSParameterAssert([NSThread isMainThread]);
    TLMUpdateOperation *op = [aNote object];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:TLMOperationFinishedNotification object:op];
    
    // ignore operations that failed or were explicitly cancelled
    if ([op failed]) {
        NSAlert *alert = [[NSAlert new] autorelease];
        [alert setMessageText:NSLocalizedString(@"The installation failed.", @"alert title")];
        [alert setInformativeText:NSLocalizedString(@"The installation process appears to have failed.  Please check the log display below for details.", @"alert message text")];
        [alert beginSheetModalForWindow:[self window] modalDelegate:nil didEndSelector:NULL contextInfo:NULL];                    
    }
    else if ([op isCancelled] == NO) {
        
        // check to see if this was an infrastructure update, which may have wiped out tlmgr
        // NB: should never happen with the new update path (always using disaster recovery)
        if (_updateInfrastructure && NO == [self _checkCommandPathAndWarn:NO]) {
            NSAlert *alert = [[NSAlert new] autorelease];
            [alert setAlertStyle:NSCriticalAlertStyle];
            [alert setMessageText:NSLocalizedString(@"The tlmgr tool no longer exists, possibly due to an update failure.", @"alert title")];
            [alert setInformativeText:[NSString stringWithFormat:NSLocalizedString(@"Follow the instructions for Unix disaster recovery on the TeX Live web site at %@.  Would you like to go to that page now?  You can also open it later from the Help menu.", @"alert message text"), @"http://tug.org/texlive/tlmgr.html"]];
            [alert addButtonWithTitle:NSLocalizedString(@"Open Now", @"button title")];
            [alert addButtonWithTitle:NSLocalizedString(@"Later", @"button title")];
            [alert beginSheetModalForWindow:[self window] 
                              modalDelegate:self 
                             didEndSelector:@selector(disasterAlertDidEnd:returnCode:contextInfo:) 
                                contextInfo:NULL];            
        }
        else {
            // This is slow, but if infrastructure was updated or a package installed other dependencies, we have no way of manually removing from the list.  We also need to ensure that the same mirror is used, so results are consistent.
            [self _refreshUpdatedPackageListFromLocation:[self _lastUpdateURL]];
        }
    }
}

- (void)_cancelAllOperations
{
    TLMLog(__func__, @"User cancelling %@", [TLMReadWriteOperationQueue defaultQueue]);
    [[TLMReadWriteOperationQueue defaultQueue] cancelAllOperations];
    
    // cancel info in case it's stuck
    [[TLMInfoController sharedInstance] cancel];
}

- (void)_handlePapersizeFinishedNotification:(NSNotification *)aNote
{
    TLMPapersizeOperation *op = [aNote object];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:TLMOperationFinishedNotification object:op];
    if ([op failed]) {
        TLMLog(__func__, @"Failed to change paper size.  Error was: %@", [op errorMessages]);
    }
}

- (void)papersizeSheetDidEnd:(NSWindow *)sheet returnCode:(NSInteger)returnCode contextInfo:(void *)context
{    
    [sheet orderOut:self];
    TLMPapersizeController *psc = context;
    [psc autorelease];
    if (TLMPapersizeChanged == returnCode && [psc paperSize]) {
        TLMPapersizeOperation *op = [[TLMPapersizeOperation alloc] initWithPapersize:[psc paperSize]];
        [self _addOperation:op selector:@selector(_handlePapersizeFinishedNotification:)];
        [op release];             
        TLMLog(__func__, @"Setting paper size to %@", [psc paperSize]);
    }
    else if (nil == [psc paperSize]) {
        TLMLog(__func__, @"No paper size from %@", psc);
    }

}

- (void)_handleListFinishedNotification:(NSNotification *)aNote
{
    TLMListOperation *op = [aNote object];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:TLMOperationFinishedNotification object:op];
    [_packageListDataSource setPackageNodes:[op packageNodes]];
    [_packageListDataSource setRefreshing:NO];
    
    NSString *statusString = nil;
    
    if ([op isCancelled])
        statusString = NSLocalizedString(@"Listing Cancelled", @"main window status string");
    else if ([op failed])
        statusString = NSLocalizedString(@"Listing Failed", @"main window status string");
    
    [self _displayStatusString:statusString];
    [_packageListDataSource setLastUpdateURL:[op updateURL]];
    [self _updateURLView];
}

- (void)_refreshFullPackageListFromLocation:(NSURL *)location
{
    [self _displayStatusString:nil];
    // disable refresh action for this view
    [_packageListDataSource setRefreshing:YES];
    TLMListOperation *op = [[TLMListOperation alloc] initWithLocation:location];
    [self _addOperation:op selector:@selector(_handleListFinishedNotification:)];
    [op release];
    TLMLog(__func__, @"Refreshing list of all packages%C", 0x2026);           
}

- (void)_handleInstallFinishedNotification:(NSNotification *)aNote
{
    TLMInstallOperation *op = [aNote object];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:TLMOperationFinishedNotification object:op];
    
    // ignore operations that failed or were explicitly cancelled
    if ([op failed]) {
        NSAlert *alert = [[NSAlert new] autorelease];
        [alert setMessageText:NSLocalizedString(@"Install failed.", @"alert title")];
        [alert setInformativeText:NSLocalizedString(@"The install process appears to have failed.  Please check the log display below for details.", @"alert message text")];
        [alert beginSheetModalForWindow:[self window] modalDelegate:nil didEndSelector:NULL contextInfo:NULL];                    
    }
    else if ([op isCancelled] == NO) {
        
        // This is slow, but if a package installed other dependencies, we have no way of manually removing from the list.  We also need to ensure that the same mirror is used, so results are consistent.
        [self _refreshFullPackageListFromLocation:[op updateURL]];
        
        // this is always displayed, so should always be updated as well
        [self _refreshUpdatedPackageListFromLocation:[op updateURL]];
    }    
}

- (void)_installPackagesWithNames:(NSArray *)packageNames reinstall:(BOOL)reinstall
{
    NSURL *currentURL = [self _lastUpdateURL];
    TLMInstallOperation *op = [[TLMInstallOperation alloc] initWithPackageNames:packageNames location:currentURL reinstall:reinstall];
    [self _addOperation:op selector:@selector(_handleInstallFinishedNotification:)];
    TLMLog(__func__, @"Beginning install of %@\nfrom %@", packageNames, [currentURL absoluteString]);   
}

- (void)_handleRemoveFinishedNotification:(NSNotification *)aNote
{
    TLMRemoveOperation *op = [aNote object];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:TLMOperationFinishedNotification object:op];
    
    // ignore operations that failed or were explicitly cancelled
    if ([op failed]) {
        NSAlert *alert = [[NSAlert new] autorelease];
        [alert setMessageText:NSLocalizedString(@"Removal failed.", @"alert title")];
        [alert setInformativeText:NSLocalizedString(@"The removal process appears to have failed.  Please check the log display below for details.", @"alert message text")];
        [alert beginSheetModalForWindow:[self window] modalDelegate:nil didEndSelector:NULL contextInfo:NULL];                    
    }
    else if ([op isCancelled] == NO) {
        
        // This is slow, but if a package removed other dependencies, we have no way of manually removing from the list.  We also need to ensure that the same mirror is used, so results are consistent.
        [self _refreshFullPackageListFromLocation:[_packageListDataSource lastUpdateURL]];
        
        // this is always displayed, so should always be updated as well
        [self _refreshUpdatedPackageListFromLocation:[_packageListDataSource lastUpdateURL]];
    }    
}

#pragma mark Alert callbacks

- (void)infrastructureAlertDidEnd:(NSAlert *)alert returnCode:(NSInteger)returnCode contextInfo:(void *)contextInfo;
{
    if (NSAlertFirstButtonReturn == returnCode) {
        [self _updateAllPackages];
    }
}

- (void)disasterAlertDidEnd:(NSAlert *)alert returnCode:(NSInteger)returnCode contextInfo:(void *)context
{
    if (NSAlertFirstButtonReturn == returnCode)
        [[NSApp delegate] openDisasterRecoveryPage:nil];
    else
        TLMLog(__func__, @"User chose not to open %@ after failure", @"http://tug.org/texlive/tlmgr.html");
}

- (void)cancelWarningSheetDidEnd:(NSAlert *)alert returnCode:(NSInteger)returnCode contextInfo:(void *)contextInfo
{
    if (NSAlertSecondButtonReturn == returnCode)
        [self _cancelAllOperations];
    else
        TLMLog(__func__, @"User decided not to cancel %@", [TLMReadWriteOperationQueue defaultQueue]);
}

- (void)updateAllAlertDidEnd:(NSAlert *)alert returnCode:(NSInteger)returnCode contextInfo:(void *)contextInfo;
{
    if (NSAlertFirstButtonReturn == returnCode) {
        [self _updateAllPackages];
    }    
}

- (void)reinstallAlertDidEnd:(NSAlert *)alert returnCode:(NSInteger)returnCode contextInfo:(void *)contextInfo
{
    if (NSAlertFirstButtonReturn == returnCode)
        [self _installPackagesWithNames:[(NSArray *)contextInfo autorelease] reinstall:YES];
}

#pragma mark Actions

- (IBAction)changePapersize:(id)sender;
{
    // sheet asserts and runs tlmgr, so make sure it exists
    if ([self _checkCommandPathAndWarn:YES]) {
        TLMPapersizeController *psc = [TLMPapersizeController new];
        [NSApp beginSheet:[psc window] 
           modalForWindow:[self window] 
            modalDelegate:self 
           didEndSelector:@selector(papersizeSheetDidEnd:returnCode:contextInfo:) 
              contextInfo:psc];
    }
}

- (IBAction)cancelAllOperations:(id)sender;
{
    if ([[TLMReadWriteOperationQueue defaultQueue] isWriting]) {
        NSAlert *alert = [[NSAlert new] autorelease];
        [alert setMessageText:NSLocalizedString(@"An installation is running!", @"alert title")];
        [alert setAlertStyle:NSCriticalAlertStyle];
        [alert setInformativeText:NSLocalizedString(@"If you cancel the installation process, it may leave your TeX installation in an unknown state.  You can ignore this warning and cancel anyway, or keep waiting until the installation finishes.", @"alert message text")];
        [alert addButtonWithTitle:NSLocalizedString(@"Keep Waiting", @"button title")];
        [alert addButtonWithTitle:NSLocalizedString(@"Cancel Anyway", @"button title")];
        [alert beginSheetModalForWindow:[self window]
                          modalDelegate:self
                         didEndSelector:@selector(cancelWarningSheetDidEnd:returnCode:contextInfo:)
                            contextInfo:NULL];
    }
    else {
        [self _cancelAllOperations];
    }
}

#pragma mark API

- (void)refreshFullPackageList
{
    [self _refreshFullPackageListFromLocation:[[TLMPreferenceController sharedPreferenceController] defaultServerURL]];
}

- (void)refreshUpdatedPackageList
{
    [self _refreshUpdatedPackageListFromLocation:[[TLMPreferenceController sharedPreferenceController] defaultServerURL]];
}

- (void)updateAllPackages;
{
    NSAlert *alert = [[NSAlert new] autorelease];
    NSUInteger size = 0;
    for (TLMPackage *pkg in [_updateListDataSource allPackages])
        size += [[pkg size] unsignedIntegerValue];
    
    [alert setMessageText:NSLocalizedString(@"Update all packages?", @"alert title")];
    // may not be correct for _updateInfrastructure, but tlmgr may remove stuff also...so leave it as-is
    NSMutableString *informativeText = [NSMutableString string];
    [informativeText appendString:NSLocalizedString(@"This will install all available updates and remove packages that no longer exist on the server.", @"alert message text")];
    
    if (size > 0) {
        
        CGFloat totalSize = size;
        NSString *sizeUnits = @"bytes";
        
        // check 1024 + 10% so the plural is always correct (at least in English)
        if (totalSize > 1127) {
            totalSize /= 1024.0;
            sizeUnits = @"kilobytes";
            
            if (totalSize > 1127) {
                totalSize /= 1024.0;
                sizeUnits = @"megabytes";
            }
        }
        
        [informativeText appendFormat:NSLocalizedString(@"  Total download size will be %.1f %@.", @"partial alert text, with double space in front, only used with tlmgr2"), totalSize, sizeUnits];
    }
    [alert setInformativeText:informativeText];
    [alert addButtonWithTitle:NSLocalizedString(@"Update", @"button title")];
    [alert addButtonWithTitle:NSLocalizedString(@"Cancel", @"button title")];
    [alert beginSheetModalForWindow:[self window] 
                      modalDelegate:self 
                     didEndSelector:@selector(updateAllAlertDidEnd:returnCode:contextInfo:) 
                        contextInfo:NULL]; 
}    

- (void)updatePackagesWithNames:(NSArray *)packageNames;
{
    NSURL *currentURL = [self _lastUpdateURL];
    TLMUpdateOperation *op = [[TLMUpdateOperation alloc] initWithPackageNames:packageNames location:currentURL];
    [self _addOperation:op selector:@selector(_handleUpdateFinishedNotification:)];
    [op release];
    TLMLog(__func__, @"Beginning update of %@\nfrom %@", packageNames, [currentURL absoluteString]);
}

// reinstall requires additional option to tlmgr
- (void)installPackagesWithNames:(NSArray *)packageNames reinstall:(BOOL)reinstall
{    
    if (reinstall) {
        NSAlert *alert = [[NSAlert new] autorelease];
        [alert setMessageText:NSLocalizedString(@"Reinstall packages?", @"alert title")];
        [alert setInformativeText:NSLocalizedString(@"Some of the packages you have selected are already installed.  Would you like to reinstall them?", @"alert message text")];
        [alert addButtonWithTitle:NSLocalizedString(@"Reinstall", @"button title")];
        [alert addButtonWithTitle:NSLocalizedString(@"Cancel", @"button title")];
        [alert beginSheetModalForWindow:[self window]
                          modalDelegate:self
                         didEndSelector:@selector(reinstallAlertDidEnd:returnCode:contextInfo:)
                            contextInfo:[packageNames copy]];
    }
    else {
        [self _installPackagesWithNames:packageNames reinstall:NO]; 
    }    
}

- (void)removePackagesWithNames:(NSArray *)packageNames force:(BOOL)force
{   
    // Some idiot could try to wipe out tlmgr itself, so let's try to prevent that...
    // NB: we can have the architecture appended to the package name, so use beginswith.
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"(SELF beginswith 'bin-texlive') OR (SELF beginswith 'texlive.infra')"];
    NSArray *packages = [packageNames filteredArrayUsingPredicate:predicate];
    
    if ([packages count]) {
        // log for debugging, then display an alert so the user has some idea of what's going on...
        TLMLog(__func__, @"Tried to remove infrastructure packages: %@", packages);
        NSAlert *alert = [[NSAlert new] autorelease];
        [alert setMessageText:NSLocalizedString(@"Some of these packages cannot be removed.", @"alert title")];
        [alert setInformativeText:[NSString stringWithFormat:NSLocalizedString(@"You are attempting to remove critical parts of the underlying TeX Live infrastructure, and I won't help you do that.", @"alert message text")]];
        [alert beginSheetModalForWindow:[self window] modalDelegate:nil didEndSelector:NULL contextInfo:NULL];
    }
    else {
        TLMRemoveOperation *op = [[TLMRemoveOperation alloc] initWithPackageNames:packageNames force:force];
        [self _addOperation:op selector:@selector(_handleRemoveFinishedNotification:)];
        [op release];
        TLMLog(__func__, @"Beginning removal of\n%@", packageNames); 
    }
}

@end
