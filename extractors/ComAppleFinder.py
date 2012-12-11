from ScriptingBridge import *
from Extractor import *
from Utilities import *

class ComAppleFinder( Extractor ):

    def __init__(self):
        super( ComAppleFinder, self ).__init__()
        self.finder = SBApplication.applicationWithBundleIdentifier_("com.apple.finder")

    def clues(self):
        # is there a selection?
        try:
          url = self.finder.selection().performSelector_('get')[0].performSelector_('URL')
        except:
          pass        
        self.clues_from_file(url)
