// 
// Copyright (c) 2011 Shun Takebayashi
// 
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
// 
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
// 
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
// 

#import "STWebArchiver.h"
#import <libxml/HTMLparser.h>
#import <libxml/xpath.h>

@interface STWebArchiver ()

- (NSArray *)valueForAttributeName:(NSString *)attributeName
			   withEvaluatingXPath:(NSString *)xpathExpression
						inDocument:(xmlDocPtr)document;
- (NSArray *)absoluteURLsForPaths:(NSArray *)paths baseURL:(NSURL *)base;

@end

@implementation STWebArchiver

- (void)archiveHTMLData:(NSData *)aData
		   textEncoding:(NSString *)anEncoding
				baseURL:(NSURL *)anURL
        completionBlock:(void (^)(NSData *))completion 
{
	dispatch_queue_t completionQueue = dispatch_queue_create("completion", DISPATCH_QUEUE_CONCURRENT);	// don't call the completion black on the same thread as you call this method. Calling thread in locked by dispatch_semaphore_wait
	dispatch_retain(completionQueue);
	
	void (^completionBlock) (NSData *inData);
	completionBlock = [completion copy];	// copy completion block to heap
	
	void (^completionBlockHandler) (NSData *inData) = nil;
	completionBlockHandler = ^(NSData *inData) {
		
		dispatch_sync(completionQueue, ^(void)
					  {
						  completionBlock(inData);
					  });
		
		[completionBlock release];
		dispatch_release(completionQueue);
	};
		
	if (aData)
	{
		htmlDocPtr doc = htmlParseDoc((xmlChar *)[aData bytes], [anEncoding UTF8String]);
		NSArray *pathsForImagesAndScripts = [self valueForAttributeName:@"src" withEvaluatingXPath:@"//script[@src]|//img[@src]" inDocument:doc];
		NSArray *pathsForStylesheets = [self valueForAttributeName:@"href" withEvaluatingXPath:@"//link[@rel='stylesheet'][@href]" inDocument:doc];
		NSArray *resourcesPaths = [pathsForImagesAndScripts arrayByAddingObjectsFromArray:pathsForStylesheets];
		NSArray *resourceUrls = [self absoluteURLsForPaths:resourcesPaths baseURL:anURL];
		
		dispatch_queue_t downloadQueue = dispatch_queue_create("Downloads", DISPATCH_QUEUE_CONCURRENT);
		dispatch_sync(downloadQueue, ^{
			NSMutableDictionary *resources = [NSMutableDictionary dictionary];
			dispatch_apply([resourceUrls count], dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT,0), ^(size_t i) {
				NSURL *url = [resourceUrls objectAtIndex:i];
				NSString *urlString = [url absoluteString];
				BOOL unfetched = NO;
				
				@synchronized (resources) 
				{
					unfetched = ![resources objectForKey:urlString];
					if (unfetched) 
					{
						[resources setObject:[NSNull null] forKey:urlString];
					}
				}
				
				if (unfetched) 
				{
					NSURLResponse *response;
					NSError *error;
					NSURLRequest *request = [NSURLRequest requestWithURL:url];
					NSData *data = [NSURLConnection sendSynchronousRequest:request
														 returningResponse:&response
																	 error:&error];
					NSMutableDictionary *resourceArchive = [NSMutableDictionary dictionaryWithObjectsAndKeys:
															urlString, @"WebResourceURL",
															[response MIMEType], @"WebResourceMIMEType",
															data, @"WebResourceData", nil];
					if ([response textEncodingName]) 
					{
						[resourceArchive setObject:[response textEncodingName] forKey:@"WebResourceTextEncodingName"];
					}
					
					@synchronized (resources) 
					{
						[resources setObject:resourceArchive forKey:urlString];
					}
				}
			});
			NSMutableDictionary *archiveSource = [NSMutableDictionary dictionaryWithObject:[resources allValues] forKey:@"WebSubresources"];
			NSMutableDictionary *mainResource = [NSMutableDictionary dictionary];
			[mainResource setObject:aData forKey:@"WebResourceData"];
			[mainResource setObject:@"" forKey:@"WebResourceFrameName"];
			[mainResource setObject:@"text/html" forKey:@"WebResourceMIMEType"];
			[mainResource setObject:anEncoding forKey:@"WebResourceTextEncodingName"];
			[mainResource setObject:[anURL absoluteString] forKey:@"WebResourceURL"];
			[archiveSource setObject:mainResource forKey:@"WebMainResource"];
			NSData *webArchive = [NSPropertyListSerialization dataFromPropertyList:archiveSource
																			format:NSPropertyListBinaryFormat_v1_0
																  errorDescription:NULL];
			completionBlockHandler(webArchive);
		});
		
		xmlFreeDoc(doc);
	}
	else 
	{
		completionBlockHandler(nil);
	}
}

- (NSArray *)valueForAttributeName:(NSString *)attributeName
			   withEvaluatingXPath:(NSString *)xpathExpression
						inDocument:(xmlDocPtr)document 
{
	xmlXPathContextPtr context = xmlXPathNewContext(document);
	xmlXPathObjectPtr xpathObject = xmlXPathEvalExpression((xmlChar *)[xpathExpression UTF8String], context);
	xmlNodeSetPtr nodes = xpathObject->nodesetval;
	NSMutableArray *results = nil;

	if (!xmlXPathNodeSetIsEmpty(nodes)) 
	{
		results = [NSMutableArray arrayWithCapacity:nodes->nodeNr];
		for (int i = 0; i < nodes->nodeNr; i++) 
		{
			xmlNodePtr node = nodes->nodeTab[i];
			char *attributeChars = (char *)xmlGetProp(node, (xmlChar *)[attributeName UTF8String]);
			NSString *attributeString = [NSString stringWithUTF8String:attributeChars];
			xmlFree(attributeChars);
			[results addObject:attributeString];
		}
	}

	xmlXPathFreeObject(xpathObject);
	xmlXPathFreeContext(context);
	return results;
}

- (NSArray *)absoluteURLsForPaths:(NSArray *)paths baseURL:(NSURL *)base 
{
	NSArray *results = nil;;

	if (base)
	{
		NSMutableArray *resultPaths = [NSMutableArray arrayWithCapacity:[paths count]];
		for (NSString *path in paths) 
		{
			[resultPaths addObject:[NSURL URLWithString:path relativeToURL:base]];
		}
		results = [[resultPaths copy] autorelease];	// make immutable
	}
	else
	{
		results = paths;	// all paths are absolut
	}
	
	return results;
}

@end
