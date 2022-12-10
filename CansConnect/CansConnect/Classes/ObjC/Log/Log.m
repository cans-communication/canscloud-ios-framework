/*
 * Copyright (c) 2010-2020 Belledonne Communications SARL.
 *
 * This file is part of linphone-iphone
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <http://www.gnu.org/licenses/>.
 */

#import "Log.h"
#import <asl.h>
#import <os/log.h>


@implementation Log

#define FILE_SIZE 17
#define DOMAIN_SIZE 3


+ (void)log:(OrtpLogLevel)severity file:(const char *)file line:(int)line format:(NSString *)format, ... {
	va_list args;
	va_start(args, format);
	NSString *str = [[NSString alloc] initWithFormat:format arguments:args];
	const char *utf8str = [str cStringUsingEncoding:NSString.defaultCStringEncoding];
	const char *filename = strchr(file, '/') ? strrchr(file, '/') + 1 : file;
	ortp_log(severity, "(%*s:%-4d) %s", FILE_SIZE, filename + MAX((int)strlen(filename) - FILE_SIZE, 0), line, utf8str);
	va_end(args);
}

+ (void)directLog:(OrtpLogLevel)level text:(NSString *)text {
    bctbx_log(BCTBX_LOG_DOMAIN, level, "%s", [text cStringUsingEncoding:NSUTF8StringEncoding]);
}

@end
