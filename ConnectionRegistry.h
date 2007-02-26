//
//  ConnectionRegistry.h
//  Connection
//
//  Created by Greg Hulands on 15/11/06.
//  Copyright 2006 __MyCompanyName__. All rights reserved.
//

#import <Cocoa/Cocoa.h>

/*
 
		This class is used across applications to have a standard registry of known connections for 
		a user. This allows them to add/modify/delete connections they have and have them reflect in
		all applications that use the connection framework.
 
		The registry also is an NSOutlineView compliant data source so you can set the registry to handle
		the population of the view.
  
 */

@class CKHostCategory, CKBonjourCategory, CKHost;

@interface ConnectionRegistry : NSObject 
{
	NSMutableArray *myConnections;
	NSMutableArray *myDraggedItems;
	CKBonjourCategory *myBonjour;
	NSDistributedNotificationCenter *myCenter;
	NSLock *myLock;
	
	NSOutlineView *myOutlineView;
	NSString *myFilter;
	NSArray *myFilteredHosts;
	
	BOOL myIsGroupEditing;
}

+ (id)sharedRegistry; //use this. DO NOT alloc one yourself

- (void)beginGroupEditing;
- (void)endGroupEditing;

- (void)addCategory:(CKHostCategory *)category;
- (void)removeCategory:(CKHostCategory *)category;

- (void)insertCategory:(CKHostCategory *)category atIndex:(unsigned)index;
- (void)insertHost:(CKHost *)host atIndex:(unsigned)index;

- (void)addHost:(CKHost *)connection;
- (void)removeHost:(CKHost *)connection;

- (NSArray *)connections;

- (NSMenu *)menu;

- (NSArray *)allHosts;
- (NSArray *)allCategories;

- (NSArray *)hostsMatching:(NSString *)query;

- (void)setFilterString:(NSString *)filter;
- (void)handleFilterableOutlineView:(NSOutlineView *)view;

@end

extern NSString *CKRegistryChangedNotification;
