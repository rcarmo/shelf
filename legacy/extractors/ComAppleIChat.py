from ScriptingBridge import *
from Extractor import *
from Utilities import *

def sort_helper(a,b):
    return a.updated() < b.updated()

class ComAppleIChat(Extractor):

    def __init__(self):
        super( ComAppleIChat, self ).__init__()
        self.ichat = SBApplication.applicationWithBundleIdentifier_("com.apple.iChat")

    def clues(self):
        if self.ichat.chats().count() == 0: return []
        # Mountain Lion Messages forces me to re-do this and look for the latest active chat
        chats = self.ichat.chats()
        sort(chats, sort_helper)
                
        username = chats[0].participants()[0].handle()

        if username:
            self.clues_from_aim( username )
            self.clues_from_jabber( username )
