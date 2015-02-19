#
#  main.py
#  PyShelf
#
#  Created by Tom Insam on 06/01/2008.
#  Copyright __MyCompanyName__ 2008. All rights reserved.
#

#import modules required by application
import objc
import Foundation
import AppKit
import os
import sys
from AppKit import *
from PyObjCTools import AppHelper

# put external deps here where py2app can find them
import urllib, urllib2
import sgmllib
import cgi
import xml.dom.minidom
import HTMLParser
import ScriptingBridge
import urlparse
import json
import WebKit

NSUserDefaults.standardUserDefaults().registerDefaults_({
    'googleSocial':False,
    'googleSocialContext':False,
    'bringAppForward':True,
    'alwaysOnTop':True,
    'firstRun':True,
    'debug':False
})

# import modules containing classes required to start application and load MainMenu.nib
import PyShelfApplication
import PyShelfWindowController

# pass control to AppKit
AppHelper.runEventLoop()
