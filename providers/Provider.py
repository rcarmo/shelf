from Foundation import *
from AppKit import *
from WebKit import *
from AddressBook import *

import urllib, urllib2
import base64
import os
import re
from time import time
import traceback

from Utilities import _info
import Cache

class Provider( object ):
    
    PROVIDERS = []
    
    @classmethod
    def addProvider( myClass, classname ):
        cls = __import__(classname, globals(), locals(), [''])
        Provider.PROVIDERS.append(getattr(cls, classname))
    
    @classmethod
    def providers( myClass ):
        return Provider.PROVIDERS

    def __init__(self, person, delegate):
        #NSLog("** Provider '%s' init"%self.__class__.__name__)
        super( Provider, self ).__init__()
        self.atoms = []
        self.running = True
        self.person = person
        self.delegate = delegate
        self.provide()
    
    def content(self):
        return "".join(self.atoms)
    
    def changed(self):
        if self.running:
            self.delegate.providerUpdated_(self)

    def provide( self ):
        pass
    
    def stop(self):
        # not enforced, it's just a hint to the processor to stop
        NSObject.cancelPreviousPerformRequestsWithTarget_( self )
        self.running = False
    

    def spinner(self):
        return "<img src='spinner.gif' class='spinner'>"
        
