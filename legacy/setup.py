#!/usr/bin/python
"""
Script for building the example.

Usage:
    python setup.py py2app
"""
from distutils.core import setup
import py2app
from glob import glob

version = "0.0.15" # update in Cache.py as well, for the User-Agent string

plist = dict(
  CFBundleName="Shelf",
  NSMainNibFile="MainMenu",
  NSPrincipalClass='PyShelfApplication',
  CFBundleIdentifier="org.jerakeen.pyshelf", # historical
  CFBundleShortVersionString=version,
  CFBundleVersion=version,
  NSHumanReadableCopyright="Copyright 2008-2010 Tom Insam. Modifications by Rui Carmo.",

  NSAppleScriptEnabled=True,
  CFBundleURLTypes=[
    dict(
      CFBundleURLName='Shelf callback',
      CFBundleURLSchemes=['shelf'],
    )
  ],

  # sparkle appcast url, for auto-updates
  SUFeedURL="http://code.movieos.org/shelf/appcast/" # doesn't exist, but it's a thing at least.
)

# TODO: open Growl.framework.zip, move the resulting folder into the right place in dist, etc.

setup(
  app=["main.py",],
  data_files= glob("resources/*.nib") + glob("resources/*.html") + glob("resources/*.gif") + glob("*.py") + glob("*/*.py") + glob("resources/*.css") + glob("resources/*.png"),
  options=dict(py2app=dict(
    plist=plist,
    iconfile="resources/Icon.icns",
    frameworks=glob("*.framework"),
  )),
)

