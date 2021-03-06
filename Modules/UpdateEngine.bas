Attribute VB_Name = "Update_Support"
'***************************************************************************
'Automatic Software Updater (note: at present this doesn't technically DO the updating (e.g. overwriting program files), it just CHECKS for updates)
'Copyright 2012-2017 by Tanner Helland
'Created: 19/August/12
'Last updated: 06/January/16
'Last update: migrate misc update functions from other modules to this one
'
'This module includes various support functions for determining if a new version of PhotoDemon is available for download.
'
'As of March 2015, this module has been completely overhauled to support live-patching of PhotoDemon and its various support files
' (plugins, languages, etc).  Various bits of update code have been moved into the new update support app in the /Support folder.
' The use of a separate patching app greatly simplified things like updating in-use binary files.
'
'Note that this code interfaces with the user preferences file so the user can opt to not check for updates and never
' be notified again. (FYI - this option can be enabled/disabled from the 'Tools' -> 'Options' menu.)
'
'All source code in this file is licensed under a modified BSD license.  This means you may use the code in your own
' projects IF you provide attribution.  For more information, please visit http://photodemon.org/about/license/
'
'***************************************************************************

Option Explicit

Public Enum UpdateCheck
    UPDATE_ERROR = 0
    UPDATE_NOT_NEEDED = 1
    UPDATE_AVAILABLE = 2
    UPDATE_UNAVAILABLE = 3
End Enum

#If False Then
    Const UPDATE_ERROR = 0
    Const UPDATE_NOT_NEEDED = 1
    Const UPDATE_AVAILABLE = 2
    Const UPDATE_UNAVAILABLE = 3
#End If

'When patching PD itself, we make a backup copy of the update XML contents.  This file provides a second failsafe checksum reference, which is
' important when patching binary EXE and DLL files.
Private m_PDPatchXML As String

'When initially parsing the update XML file (above), if an update is found, the parse routine will note which track was used for the update,
' and where that track's data starts and ends inside the XML file.
Private m_SelectedTrack As Long, m_TrackStartPosition As Long, m_TrackEndPosition As Long

'If an update package is downloaded successfully, it will be forwarded to this module.  At program shutdown time, the package will be applied.
Private m_UpdateFilePath As String

'If an update is available, that update's release announcement will be stored in this persistent string.  UI elements can retrieve it as necessary.
Private m_UpdateReleaseAnnouncementURL As String

'If an update is available, that update's track will be stored here.  UI elements can retrieve it as necessary.
Private m_UpdateTrack As PD_UPDATE_TRACK

'Outside functions can also request the update version
Private m_UpdateVersion As String

'Beta releases use custom labeling, independent of the actual version (e.g. "PD 6.6 beta 3"), so we also retrieve and store this value as necessary.
Private m_BetaNumber As String


'Determine if the program should check online for update information.  This will return true IFF the following
' criteria are met:
' 1) User preferences allow us to check for updates (e.g. the user has not forcibly disabled such checks)
' 2) At least 10 days have passed since the last update check...
' 3) ...or 10 days haven't passed, but we have never checked for updates before, and this is NOT the first time the user
'    is running the program
Public Function IsItTimeForAnUpdate() As Boolean

    'Locale settings can sometimes screw with the DateDiff function in unpredictable ways.  (For example, if a
    ' user is using PD on a pen drive, and they move between PCs with wildly different date representations)
    ' If something goes wrong at any point in this function, we'll simply disable update checks until next run.
    On Error GoTo noUpdates

    Dim allowedToUpdate As Boolean
    allowedToUpdate = False
    
    'Previous to v6.6, PD's update preference was a binary yes/no thing.  To make sure users who previously disabled
    ' updates are respected, if the new preference doesn't exist yet, we'll use the old preference value instead.
    Dim updateFrequency As PD_UPDATE_FREQUENCY
    updateFrequency = PDUF_EACH_SESSION
    If g_UserPreferences.DoesValueExist("Updates", "Check For Updates") Then
        
        If Not g_UserPreferences.GetPref_Boolean("Updates", "Check For Updates", True) Then
            
            'Write a matching preference in the new format.
            g_UserPreferences.SetPref_Long "Updates", "Update Frequency", PDUF_NEVER
            
            'Overwrite the old preference, so it doesn't trigger this check again
            g_UserPreferences.SetPref_Boolean "Updates", "Check For Updates", True
            
        End If
        
    End If
    
    'In v6.6, PD's update strategy was modified to allow the user to specify an update frequency (rather than
    ' a binary yes/no preference).  Retrieve the allowed frequency now.
    If updateFrequency <> PDUF_NEVER Then
        updateFrequency = g_UserPreferences.GetPref_Long("Updates", "Update Frequency", PDUF_EACH_SESSION)
    End If
        
    'If updates ARE allowed, see when we last checked for an update.  If enough time has elapsed, check again.
    If updateFrequency <> PDUF_NEVER Then
    
        Dim lastCheckDate As String
        lastCheckDate = g_UserPreferences.GetPref_String("Updates", "Last Update Check", "")
        
        'If a "last update check date" was not found, request an immediate update check.
        If Len(lastCheckDate) = 0 Then
        
            allowedToUpdate = True
        
        'If a last update check date was found, check to see how much time has elapsed since that check.
        Else
        
            'Start by figuring out how many days need to have passed before we're allowed to check for updates
            ' again.  (This varies according to user preference.)
            Dim numAllowableDays As Long
            
            Select Case updateFrequency
            
                Case PDUF_EACH_SESSION
                    numAllowableDays = 0
                
                Case PDUF_WEEKLY
                    numAllowableDays = 7
                    
                Case PDUF_MONTHLY
                    numAllowableDays = 30
            
            End Select
            
            Dim currentDate As Date
            currentDate = Format$(Now, "Medium Date")
            
            'If the allowable date threshold has passed, allow the updater to perform a new check
            If CLng(DateDiff("d", CDate(lastCheckDate), currentDate)) >= numAllowableDays Then
                allowedToUpdate = True
            
            'If 10 days haven't passed, prevent an update
            Else
                Message "Update check postponed (a check has been performed recently)"
                allowedToUpdate = False
            End If
                    
        End If
    
    'If the user has specified "never" as their desired update frequency, we'll always return FALSE.
    Else
        allowedToUpdate = False
    End If
    
    IsItTimeForAnUpdate = allowedToUpdate
    
    Exit Function

'In the event of an error, simply disallow updates for this session.
noUpdates:

    IsItTimeForAnUpdate = False
    
End Function

'Given the XML string of a download language version XML report from photodemon.org, initiate downloads of any languages that need to be updated.
Public Sub ProcessLanguageUpdateFile(ByRef srcXML As String)
    
    'This boolean array will be track which (if any) language files are in need of an update.  The matching "numOfUpdates"
    ' value will be > 0 if any files need updating.
    Dim numOfUpdates As Long
    numOfUpdates = 0
    
    Dim updateFlags() As Boolean
    
    'We will be testing a number of different languages to see if they qualify for an update.  This temporary object will
    ' be passed to the public translation class as necessary, to retrieve a copy of a given language file's data.
    Dim tmpLanguage As pdLanguageFile
        
    'A pdXML object handles XML parsing for us.
    Dim xmlEngine As pdXML
    Set xmlEngine = New pdXML
    
    Dim langVersion As String, langID As String, langRevision As Long
    
    'Validate the XML
    If xmlEngine.LoadXMLFromString(srcXML) Then
    
        'Check for a few necessary tags, just to make sure this is actually a PhotoDemon language file
        If xmlEngine.IsPDDataType("Language versions") Then
        
            'We're now going to enumerate all language tags in the file.  If one needs to be updated, a couple extra
            ' steps need to be taken.
            Dim langList() As String
            If xmlEngine.FindAllAttributeValues(langList, "language", "updateID") Then
                
                'langList() now contains a list of all the unique language listings in the update file.
                ' We want to search this list for entries with an identical major/minor version to this PD build.
                
                'Start by retrieving the current PD executable version.
                Dim currentPDVersion As String
                currentPDVersion = GetPhotoDemonVersionMajorMinorOnly
                
                'This step is simply going to flag language files in need of an update.  This array will be used to track
                ' such language; a separate step will initiate the actual update downloads.
                ReDim updateFlags(0 To UBound(langList)) As Boolean
                
                'Iterate the language update list, looking for version matches
                Dim i As Long
                For i = LBound(langList) To UBound(langList)
                
                    'Retrieve the major/minor version of this language file.  (String format is fine, as we're just
                    ' checking equality.)
                    langVersion = xmlEngine.GetUniqueTag_String("version", , , "language", "updateID", langList(i))
                    langVersion = RetrieveVersionMajorMinorAsString(langVersion)
                    
                    'Retrieve the language's revision as well.  This is explicitly retrieved as a LONG, because we need to perform
                    ' a >= check between it and the current language file revision.
                    langRevision = xmlEngine.GetUniqueTag_String("revision", , , "language", "updateID", langList(i))
                    
                    'If the version matches this .exe version, this language file is a candidate for updating.
                    If StrComp(currentPDVersion, langVersion, vbBinaryCompare) = 0 Then
                    
                        'Next, we need to compare the versions of the update language file and the installed language file.
                        
                        'Retrieve the language ID, which is a unique identifier.
                        langID = xmlEngine.GetUniqueTag_String("id", , , "language", "updateID", langList(i))
                        
                        'Use a helper function to retrieve the language header for the currently installed copy of this language.
                        If g_Language.GetPDLanguageFileObject(tmpLanguage, langID) Then
                        
                            'A matching language file was found.  Compare version numbers.
                            If StrComp(langVersion, RetrieveVersionMajorMinorAsString(tmpLanguage.langVersion), vbBinaryCompare) = 0 Then
                            
                                'The major/minor version of this language file matches the current language.  Compare revisions.
                                If langRevision > RetrieveVersionRevisionAsLong(tmpLanguage.langVersion) Then
                                
                                    'Holy shit, this language actually needs to be updated!  :P  Mark the corresponding location
                                    ' in the update array, and increment the update counter.
                                    updateFlags(i) = True
                                    numOfUpdates = numOfUpdates + 1
                                    
                                    #If DEBUGMODE = 1 Then
                                        pdDebug.LogAction "Language ID " & langID & " will be updated to revision " & langRevision & "."
                                    #End If
                                
                                'The current file is up-to-date.
                                Else
                                
                                    Debug.Print "Language ID " & langID & " is already up-to-date (updated: "; langVersion & "." & langRevision & ", current: "; RetrieveVersionMajorMinorAsString(tmpLanguage.langVersion) & "." & RetrieveVersionRevisionAsLong(tmpLanguage.langVersion) & ")"
                                
                                End If
                            
                            End If
                            
                        'This language ID was not found.  This could mean one of two things:
                        ' 1) This language file is a new one (e.g. it was not included in the original release of this PD version)
                        ' 2) The user forcibly deleted this language file at some point in the past.
                        '
                        'To avoid undoing (2), we must also ignore (1).  Do nothing if this language file doesn't exist in the
                        ' current languages folder.
                        Else
                            Debug.Print "Language ID " & langID & " does not exist on this PC.  No update will be performed."
                        End If
                    
                    End If
                    
                Next i
            
            End If
        
            'At this point, updateFlags() will contain TRUE for any language files that need to be updated, and numOfUpdates should
            ' be greater than 0 if updates are required.
            If numOfUpdates > 0 Then
                
                Dim reportedChecksum As Long
                Dim langFilename As String, langLocation As String, langURL As String
                
                Debug.Print numOfUpdates & " updated language files will now be downloaded."
                
                'Loop through the update array; for any language marked for update, request an asynchronous download of their
                ' matching file from the main form.
                For i = 0 To UBound(updateFlags)
                
                    If updateFlags(i) Then
                    
                        'Retrieve the matching checksum for this language; we'll be passing this to the downloader, so it can verify
                        ' the downloaded file prior to us unpacking it.
                        reportedChecksum = CLng(xmlEngine.GetUniqueTag_String("checksum", "0", , "language", "updateID", langList(i)))
                        
                        'Retrieve the filename and location folder for this language; we need these to construct a URL
                        langFilename = xmlEngine.GetUniqueTag_String("filename", , , "language", "updateID", langList(i))
                        langLocation = xmlEngine.GetUniqueTag_String("location", , , "language", "updateID", langList(i))
                        
                        'Construct a matching URL
                        langURL = "http://photodemon.org/downloads/languages/"
                        If StrComp(UCase(langLocation), "STABLE", vbBinaryCompare) = 0 Then
                            langURL = langURL & "stable/"
                        Else
                            langURL = langURL & "nightly/"
                        End If
                        langURL = langURL & langFilename & ".pdz"
                        
                        'Request a download on the main form.  Note that we explicitly set the download type to the pdLanguage file
                        ' header constant; this lets us easily sort the incoming downloads as they arrive.  We also use the reported
                        ' checksum as the file's unique ID value.  Post-download and extraction, we use this value to ensure that
                        ' the extracted data matches what we originally uploaded.
                        If FormMain.RequestAsynchronousDownload(reportedChecksum, langURL, PD_LANG_IDENTIFIER, vbAsyncReadForceUpdate, True, g_UserPreferences.GetUpdatePath & langFilename & ".tmp") Then
                            Debug.Print "Download successfully initiated for language update at " & langURL
                        Else
                            Debug.Print "WARNING! FormMain.requestAsynchronousDownload refused to initiate download of " & langID & " language file update."
                        End If
                                            
                    End If
                
                Next i
                
            Else
                Debug.Print "All language files are up-to-date.  No new files will be downloaded."
            End If
        
        Else
            Debug.Print "WARNING! Language update XML did not pass basic validation.  Abandoning update process."
        End If
    
    Else
        Debug.Print "WARNING! Language update XML did not load successfully - check for an encoding error, maybe...?"
    End If
    
End Sub

'After a language file has successfully downloaded, FormMain calls this function to actually apply the patch.
Public Function PatchLanguageFile(ByVal entryKey As String, downloadedData() As Byte, ByVal savedToThisFile As String) As Boolean
    
    On Error GoTo LanguagePatchingFailure
    
    'A pdFSO object handles file and path interactions
    Dim cFile As pdFSO
    Set cFile = New pdFSO
    
    'The downloaded data is saved in the /Data/Updates folder.  Retrieve it directly into a pdPackager object.
    Dim cPackage As pdPackager
    Set cPackage = New pdPackager
    cPackage.Init_ZLib "", True, g_ZLibEnabled
    
    If cPackage.ReadPackageFromFile(savedToThisFile) Then
    
        'The package appears to be intact.  Attempt to retrieve the embedded language file.
        Dim rawNewFile() As Byte, newFilenameArray() As Byte, newFilename As String, newChecksum As Long
        Dim rawOldFile() As Byte
        If cPackage.GetNodeDataByIndex(0, False, rawNewFile) Then
        
            'If we made it here, it means the internal pdPackage checksum passed successfully, meaning the post-compression file checksum
            ' matches the original checksum calculated at creation time.  Because we are very cautious, we now apply a second checksum verification,
            ' using the checksum value embedded within the original langupdate.xml file.  (For convenience, that checksum was passed to us as
            ' the download key.)
            newChecksum = CLng(entryKey)
            
            If newChecksum = cPackage.ChecksumArbitraryArray(rawNewFile) Then
                
                'Checksums match!  We now want to overwrite the old language file with the new one.
                
                'Retrieve the filename of the updated language file
                If cPackage.GetNodeDataByIndex(0, True, newFilenameArray) Then
                    
                    newFilename = Space$((UBound(newFilenameArray) + 1) \ 2)
                    CopyMemory ByVal StrPtr(newFilename), ByVal VarPtr(newFilenameArray(0)), UBound(newFilenameArray) + 1
                    
                    'See if that file already exists.  Note that a modified path is required for the MASTER language file, which sits
                    ' in a dedicated subfolder.
                    If StrComp(UCase(newFilename), "MASTER.XML", vbBinaryCompare) = 0 Then
                        newFilename = g_UserPreferences.GetLanguagePath() & "MASTER\" & newFilename
                    Else
                        newFilename = g_UserPreferences.GetLanguagePath() & newFilename
                    End If
                    
                    If cFile.FileExist(newFilename) Then
                        
                        'Make a temporary backup of the existing file, then delete it
                        cFile.LoadFileAsByteArray newFilename, rawOldFile
                        cFile.KillFile newFilename
                        
                    End If
                    
                    'Write out the new file
                    If cFile.SaveByteArrayToFile(rawNewFile, newFilename) Then
                    
                        'Perform a final failsafe checksum verification of the extracted file
                        If (newChecksum = cPackage.ChecksumArbitraryFile(newFilename)) Then
                            PatchLanguageFile = True
                        Else
                            'Failsafe checksum verification didn't pass.  Restore the old file.
                            Debug.Print "WARNING!  Downloaded language file was written, but final checksum failsafe failed.  Restoring old language file..."
                            cFile.SaveByteArrayToFile rawOldFile, newFilename
                            PatchLanguageFile = False
                        End If
                        
                    End If
                
                Else
                    Debug.Print "WARNING! pdPackage refused to return filename."
                    PatchLanguageFile = False
                End If
                
            Else
                Debug.Print "WARNING! Secondary checksum failsafe failed (" & newChecksum & " != " & cPackage.ChecksumArbitraryArray(rawNewFile) & ").  Language update abandoned."
                PatchLanguageFile = False
            End If
        
        End If
    
    Else
        Debug.Print "WARNING! Language file downloaded, but pdPackager rejected it.  Language update abandoned."
        PatchLanguageFile = False
    End If
    
    'Regardless of outcome, we kill the update file when we're done with it.
    cFile.KillFile savedToThisFile
    
    Exit Function
    
LanguagePatchingFailure:

    PatchLanguageFile = False
    
End Function

'Given the XML string of a download program version XML report from photodemon.org, initiate the download of a program update package, as necessary.
' This function basically checks to see if PhotoDemon.exe is out of date on the current update track (stable, beta, or nightly, per the user's
' preference).  If it is, an update package will be downloaded.  At extraction time, all files that need to be updated, will be updated; this function's
' job is simply to initiate a larger package download if necessary.
'
'Returns TRUE is an update is available; FALSE otherwise
Public Function ProcessProgramUpdateFile(ByRef srcXML As String) As Boolean
    
    'In most cases, we assume there to *not* be an update
    ProcessProgramUpdateFile = False
    
    'A pdXML object handles XML parsing for us.
    Dim xmlEngine As pdXML
    Set xmlEngine = New pdXML
    
    'Validate the XML
    If xmlEngine.LoadXMLFromString(srcXML) Then
    
        'Check for a few necessary tags, just to make sure this is actually a valid update file
        If xmlEngine.IsPDDataType("Program version") Then
            
            'Next, figure out which update track we need to check.  The user can change this at any time, so it may not necessarily correlate to
            ' the current build.  (e.g., if the user is on the stable track, they may switch to the nightly track, which necessitates a different
            ' update procedure).
            Dim curUpdateTrack As PD_UPDATE_TRACK
            curUpdateTrack = g_UserPreferences.GetPref_Long("Updates", "Update Track", PDUT_BETA)
            
            'From the update track, we need to generate a string that identifies the correct chunk of the XML file.  Some update tracks can update
            ' to more than one type of build (for example, the nightly build track can update to a stable version, if the stable version is newer),
            ' so we may need to search multiple regions of the update file in order to find the best update target.
            Dim updateTagIDs() As String, numUpdateTagIDs As Long
            ReDim updateTagIDs(0 To 2) As String
            updateTagIDs(0) = "stable"
            updateTagIDs(1) = "beta"
            updateTagIDs(2) = "nightly"
            
            Select Case curUpdateTrack
            
                Case PDUT_STABLE
                    numUpdateTagIDs = 1
                    
                Case PDUT_BETA
                    numUpdateTagIDs = 2
                
                Case PDUT_NIGHTLY
                    numUpdateTagIDs = 3
                
            End Select
            
            ReDim Preserve updateTagIDs(0 To numUpdateTagIDs - 1) As String
            
            'If we find an update track with a valid update available, this value will point at that track (0, 1, or 2, for stable, beta,
            ' or nightly, respectively).  If no update is found, it will remain at -1.
            Dim trackWithValidUpdate As Long
            trackWithValidUpdate = -1
            
            'We start with the current PD version as a baseline.  If newer update targets are found, this string will be updated with those targets instead.
            Dim curVersionMatch As String
            curVersionMatch = GetPhotoDemonVersionCanonical()
            
            'FAKE TESTING VERSION ONLY!
            'curVersionMatch = "6.4.0"
            
            'Next, we need to search the update file for PhotoDemon.exe versions.  Each valid updateTagID region (as calculated above) will be
            ' searched.  If any return a hit, we will initiate the download of an update package.
            Dim i As Long
            For i = 0 To numUpdateTagIDs - 1
            
                'Find the bounding character markers for the relevant XML region (e.g. the one that corresponds to this update track)
                Dim tagAreaStart As Long, tagAreaEnd As Long
                If xmlEngine.GetTagCharacterRange(tagAreaStart, tagAreaEnd, "update", "track", updateTagIDs(i)) Then
                    
                    'Find the position of the PhotoDemon.exe version
                    Dim pdTagPosition As Long
                    pdTagPosition = xmlEngine.GetLocationOfTagPlusAttribute("version", "component", "PhotoDemon.exe", tagAreaStart)
                    
                    'Make sure the tag position is within the valid range.  (This should always be TRUE, but it doesn't hurt to check.)
                    If (pdTagPosition >= tagAreaStart) And (pdTagPosition <= tagAreaEnd) Then
                    
                        'This is the version tag we want!  Retrieve its value.
                        Dim newPDVersionString As String
                        newPDVersionString = xmlEngine.GetTagValueAtPreciseLocation(pdTagPosition)
                        
                        Debug.Print "Update track " & i & " reports version " & newPDVersionString & " (our version: " & GetPhotoDemonVersionCanonical() & ")"
                        
                        'If this value is higher than our current update target, mark it and proceed.  Note that this approach gives us the
                        ' highest possible update target from all available/enabled update tracks.
                        If IsNewVersionHigher(curVersionMatch, newPDVersionString) Then
                            
                            trackWithValidUpdate = i
                            
                            'Set some matching module-level values, which we'll need when it's time to actually patch the files in question.
                            m_SelectedTrack = trackWithValidUpdate
                            m_TrackStartPosition = tagAreaStart
                            m_TrackEndPosition = tagAreaEnd
                            m_UpdateVersion = newPDVersionString
                            m_UpdateReleaseAnnouncementURL = xmlEngine.GetUniqueTag_String("raurl-" & updateTagIDs(i))
                            
                        End If
                        
                    End If
                
                'This Else branch should never trigger, as it means the update file doesn't contain the listed update track.
                Else
                    #If DEBUGMODE = 1 Then
                        pdDebug.LogAction "WARNING!  Update XML file is possibly corrupt, as the requested update track could not be located within the file."
                    #End If
                End If
                
            Next i
            
            'If trackWithValidUpdate is >= 0, it points to the update track with the highest possible update target.
            If trackWithValidUpdate >= 0 Then
            
                'Make a backup copy of the update XML string.  We'll need to refer to it later, after the patch files have downloaded,
                ' as it contains failsafe checksumming information.
                m_PDPatchXML = xmlEngine.ReturnCurrentXMLString(True)
                
                'We also want to cache the current update track at module-level, so we can display customized update notifications to the user
                m_UpdateTrack = trackWithValidUpdate
                
                'Retrieve the manually listed beta number, just in case we need it later
                m_BetaNumber = xmlEngine.GetUniqueTag_String("releasenumber-beta", "1")
                
                'Construct a URL that matches the selected update track
                Dim updateURL As String
                updateURL = "http://photodemon.org/downloads/updates/"
                
                Select Case trackWithValidUpdate
                
                    Case PDUT_STABLE
                        updateURL = updateURL & "stable"
                    
                    Case PDUT_BETA
                        updateURL = updateURL & "beta"
                
                    Case PDUT_NIGHTLY
                        updateURL = updateURL & "nightly"
                
                End Select
                
                updateURL = updateURL & ".pdz"

                'Request a download on the main form.  Note that we explicitly set the download type to the pdLanguage file
                ' header constant; this lets us easily sort the incoming downloads as they arrive.  We also use the reported
                ' checksum as the file's unique ID value.  Post-download and extraction, we use this value to ensure that
                ' the extracted data matches what we originally uploaded.
                If FormMain.RequestAsynchronousDownload("PD_UPDATE_PATCH", updateURL, PD_PATCH_IDENTIFIER, vbAsyncReadForceUpdate, True, g_UserPreferences.GetUpdatePath & "PDPatch.tmp") Then
                    
                    Debug.Print "Download successfully initiated for program patch file at " & updateURL
                    
                    'Only now do we report SUCCESS to the caller
                    ProcessProgramUpdateFile = True
                    
                Else
                    Debug.Print "WARNING! FormMain.requestAsynchronousDownload refused to initiate download of " & updateURL & " patch file."
                End If
                
            'No update was found.  Exit now.
            Else
            
                #If DEBUGMODE = 1 Then
                    pdDebug.LogAction "Update check performed successfully.  (No update available right now.)"
                #End If
            
            End If
        
        Else
            Debug.Print "WARNING! Program update XML did not pass basic validation.  Abandoning update process."
        End If
    
    Else
        Debug.Print "WARNING! Program update XML did not load successfully - check for an encoding error, maybe...?"
    End If
    
End Function

'When live-patching program files, we double-check checksums of both the temp files and the final binary copies.  This prevents hijackers from
' intercepting the files mid-transit, and replacing them with their own.
Private Function GetFailsafeChecksum(ByRef xmlEngine As pdXML, ByVal relativePath As String) As Long

    'Find the position of this file's checksum
    Dim pdTagPosition As Long
    pdTagPosition = xmlEngine.GetLocationOfTagPlusAttribute("checksum", "component", relativePath, m_TrackStartPosition)
    
    'Make sure the tag position is within the valid range.  (This should always be TRUE, but it doesn't hurt to check.)
    If (pdTagPosition >= m_TrackStartPosition) And (pdTagPosition <= m_TrackEndPosition) Then
    
        'This is the checksum tag we want!  Retrieve its value.
        Dim thisChecksum As String
        thisChecksum = xmlEngine.GetTagValueAtPreciseLocation(pdTagPosition)
        
        'Convert the checksum to a long and return it
        GetFailsafeChecksum = thisChecksum
        
    'If the checksum doesn't exist in the file, return 0
    Else
        GetFailsafeChecksum = 0
    End If
    
    'Debug.Print pdTagPosition & " (" & m_TrackStartPosition & ", " & m_TrackEndPosition & "): " & relativePath
    
End Function

'If a program update file has successfully downloaded during this session, FormMain calls this function at program termination.
' This lovely function actually patches any/all relevant files.
Public Function PatchProgramFiles() As Boolean
    
    On Error GoTo ProgramPatchingFailure
    
    'If no update file is available, exit without doing anything
    If Len(m_UpdateFilePath) = 0 Then
        PatchProgramFiles = True
        Exit Function
    End If
    
    'Write the update XML file out to file, so the separate patching app can access it
    Dim tmpXML As pdXML
    Set tmpXML = New pdXML
    tmpXML.LoadXMLFromString m_PDPatchXML
    tmpXML.WriteXMLToFile g_UserPreferences.GetUpdatePath & "patch.xml", True
    
    'The patching .exe is embedded inside the update package.  Extract it now.
    Dim cPackage As pdPackager
    Set cPackage = New pdPackager
    cPackage.Init_ZLib "", True, g_ZLibEnabled
    
    Dim patchFileName As String
    patchFileName = "PD_Update_Patcher.exe"
    
    If cPackage.ReadPackageFromFile(m_UpdateFilePath, PD_PATCH_IDENTIFIER) Then
        cPackage.AutoExtractSingleFile g_UserPreferences.GetProgramPath, patchFileName, , 99
    Else
        #If DEBUGMODE = 1 Then
            pdDebug.LogAction "WARNING!  Patch program wasn't found inside the update package.  Patching will not proceed."
        #End If
    End If
    
    'All that's left to do is shell the patch .exe.  It will wait for PD to close, then initiate the patching process.
    Dim patchParams As String
    If g_UserWantsRestart Then patchParams = "/restart"
    
    'We must tell the patcher where to find the update information
    patchParams = patchParams & " /start " & m_TrackStartPosition & " /end " & m_TrackEndPosition
    
    Dim targetPath As String
    targetPath = g_UserPreferences.GetProgramPath & patchFileName
    
    Dim shellReturn As Long
    shellReturn = ShellExecute(0, 0, StrPtr(targetPath), StrPtr(patchParams), 0, 0)
    
    'ShellExecute returns a value > 32 if successful (https://msdn.microsoft.com/en-us/library/windows/desktop/bb762153%28v=vs.85%29.aspx)
    If shellReturn < 32 Then
        #If DEBUGMODE = 1 Then
            pdDebug.LogAction "ShellExecute could not launch the updater!  It returned code #" & shellReturn & "."
        #End If
    Else
        #If DEBUGMODE = 1 Then
            pdDebug.LogAction "ShellExecute returned success.  Updater should launch momentarily..."
        #End If
    End If
    
    'Exit now
    PatchProgramFiles = True
    Exit Function
    
ProgramPatchingFailure:

    PatchProgramFiles = False
    
End Function

'Rather than apply updates mid-session, any patches are applied by a separate application, at shutdown time
Public Sub NotifyUpdatePackageAvailable(ByVal tmpUpdateFile As String)
    m_UpdateFilePath = tmpUpdateFile
End Sub

Public Function IsUpdatePackageAvailable() As Boolean
    IsUpdatePackageAvailable = (Len(m_UpdateFilePath) <> 0)
End Function

'Replacing files at run-time is unpredictable; sometimes we can delete the files, sometimes we can't.
'
'As such, this function is called when PD starts. It scans the update folder for old temp files and deletes them as encountered.
Public Sub CleanPreviousUpdateFiles()
    
    #If DEBUGMODE = 1 Then
        pdDebug.LogAction "Looking for previous update files and cleaning as necessary..."
    #End If
    
    'Use pdFSO to generate a list of .tmp files in the Update folder
    Dim tmpFileList As pdStringStack
    Set tmpFileList = New pdStringStack
    
    Dim cFile As pdFSO
    Set cFile = New pdFSO
    
    Dim tmpFile As String
        
    'First, we hard-code a few XML files that may exist due to old PD update methods
    tmpFileList.AddString g_UserPreferences.GetUpdatePath & "patch.xml"
    tmpFileList.AddString g_UserPreferences.GetUpdatePath & "pdupdate.xml"
    tmpFileList.AddString g_UserPreferences.GetUpdatePath & "updates.xml"
    
    'Next, we auto-add any .tmp files in the update folder, which should cover all other potential use-cases
    cFile.RetrieveAllFiles g_UserPreferences.GetUpdatePath, tmpFileList, False, False, "TMP|tmp"
    
    'If temp files exist, remove them now.
    Do While tmpFileList.PopString(tmpFile)
        
        cFile.KillFile tmpFile
        
        #If DEBUGMODE = 1 Then
            pdDebug.LogAction "Found and deleting update file: " & tmpFile
        #End If
    
    Loop
        
    'Do the same thing for temp files in the base PD folder
    Set tmpFileList = Nothing
    If cFile.RetrieveAllFiles(g_UserPreferences.GetProgramPath, tmpFileList, False, False, "TMP|tmp") Then
        
        Do While tmpFileList.PopString(tmpFile)
            
            cFile.KillFile tmpFile
            
            #If DEBUGMODE = 1 Then
                pdDebug.LogAction "Found and deleting update file: " & tmpFile
            #End If
            
        Loop
        
    End If
        
    '...And just to be safe, do the same thing for temp files in the plugin folder
    Set tmpFileList = Nothing
    If cFile.RetrieveAllFiles(g_PluginPath, tmpFileList, False, False, "TMP|tmp") Then
        
        Do While tmpFileList.PopString(tmpFile)
        
            cFile.KillFile tmpFile
            
            #If DEBUGMODE = 1 Then
                pdDebug.LogAction "Found and deleting update file: " & tmpFile
            #End If
            
        Loop
        
    End If
    
    'Finally, delete the patch exe itself, which will have closed by now
    cFile.KillFile g_UserPreferences.GetProgramPath & "PD_Update_Patcher.exe"
    
End Sub

'At start-up, PD calls this function to find out if the program started via a PD-generated restart event (e.g. the presence of restart.bat).
' Returns TRUE if restart.bat is found; FALSE otherwise.
' (Also, this function deletes restart.bat if present)
Public Function WasProgramStartedViaRestart() As Boolean
    
    Dim restartFile As String
    restartFile = g_UserPreferences.GetProgramPath & "PD_Update_Patcher.exe"
    
    Dim cFile As pdFSO
    Set cFile = New pdFSO
    
    If cFile.FileExist(restartFile) Then
        
        cFile.KillFile restartFile
        
        #If DEBUGMODE = 1 Then
            pdDebug.LogAction "FYI: this session was started by an update process (PD_Update_Patcher is present)"
        #End If
        
        WasProgramStartedViaRestart = True
    Else
        
        #If DEBUGMODE = 1 Then
            pdDebug.LogAction "FYI: this session was started by the user (PD_Update_Patcher is not present)"
        #End If
    
        WasProgramStartedViaRestart = False
    End If
    
End Function

'If an update is ready, you may call this function to display an update notification to the user
Public Sub DisplayUpdateNotification()
    
    'If a modal dialog is active, raising a new window will cause a crash; we must deal with this accordingly
    On Error GoTo couldNotDisplayUpdateNotification
    
    'Suspend any previous update notification flags
    g_ShowUpdateNotification = False
    
    'Check user preferences; they can choose to ignore update notifications
    If g_UserPreferences.GetPref_Boolean("Updates", "Update Notifications", True) Then
    
        'Display the dialog
        FormUpdateNotify.Show vbModeless, FormMain
        
    End If
    
    Exit Sub
    
couldNotDisplayUpdateNotification:

    'Set a global flag; PD's central processor will use this to display the notification as soon as it reasonably can
    g_ShowUpdateNotification = True

End Sub

'PD should always be able to provide a release announcement URL, but I still recommend testing this string for emptiness prior to displaying
' it to the user.
Public Function GetReleaseAnnouncementURL() As String
    GetReleaseAnnouncementURL = m_UpdateReleaseAnnouncementURL
End Function

'Outside functions can also the track of the currently active update.  Note that this doesn't predictably correspond to the user's current
' update preference, as most users will allow updates from multiple potential tracks (e.g. both stable and beta).
Public Function GetUpdateTrack() As PD_UPDATE_TRACK
    GetUpdateTrack = m_UpdateTrack
End Function

'Outside functions can also request a human-readable string of the literal update number (e.g. Major.Minor.Build, untouched).
Public Function GetUpdateVersion_Literal(Optional ByVal forceRevisionDisplay As Boolean = False) As String
    
    'Parse the version string, which is currently on the form Major.Minor.Build.Revision
    Dim verStrings() As String
    verStrings = Split(m_UpdateVersion, ".")
    If UBound(verStrings) < 2 Then verStrings = Split(m_UpdateVersion, ",")
    
    'We always want major and minor version numbers
    If UBound(verStrings) >= 1 Then
        
        GetUpdateVersion_Literal = verStrings(0) & "." & verStrings(1)
        
        'If the revision value is non-zero, or the user demands a revision number, include it
        If (UBound(verStrings) >= 3) Or forceRevisionDisplay Then
            
            'If the revision number exists, use it
            If UBound(verStrings) >= 3 Then
                If StrComp(verStrings(3), "0", vbBinaryCompare) <> 0 Then GetUpdateVersion_Literal = GetUpdateVersion_Literal & "." & verStrings(3)
            
            'If the revision number does not exist, append 0 in its place
            Else
                GetUpdateVersion_Literal = GetUpdateVersion_Literal & ".0"
            End If
            
        End If
        
    Else
        GetUpdateVersion_Literal = m_UpdateVersion
    End If
    
End Function

'Outside functions can use this to request a human-readable string of the "friendly" update number (e.g. beta releases are properly identified and
' bumped up to the next stable release).
Public Function GetUpdateVersion_Friendly() As String
    
    'Start by retrieving the literal version number
    Dim litVersion As String
    litVersion = GetUpdateVersion_Literal(True)
    
    'If the current update track is *NOT* a beta, the friendly string matches the literal string.  Return it now.
    If m_UpdateTrack <> PDUT_BETA Then
        GetUpdateVersion_Friendly = litVersion
    
    'If the current update track *IS* a beta, we need to manually update the number prior to returning it
    Else
        
        On Error GoTo VersionFormatError
        
        'Start by extracting all version numbers
        Dim vSplit() As String
        vSplit = Split(litVersion, ".")
        
        Dim vMajor As Long, vMinor As Long, vRevision As Long
        
        vMajor = vSplit(0)
        vMinor = vSplit(1)
        vRevision = vSplit(2)
        
        'Bump minor by 1
        vMinor = vMinor + 1
        
        'Account for .10, which means a release to the next major version (e.g. 6.9 leads to 7.0, not 6.10)
        If vMinor = 10 Then
            vMinor = 0
            vMajor = vMajor + 1
        End If
        
        'Construct a new version string
        GetUpdateVersion_Friendly = g_Language.TranslateMessage("%1.%2 Beta %3", vMajor, vMinor, m_BetaNumber)
        
    End If
    
    Exit Function
    
VersionFormatError:

    GetUpdateVersion_Friendly = litVersion

End Function

'Retrieve PD's current name and version, modified against "beta" labels, etc
Public Function GetPhotoDemonNameAndVersion() As String
    GetPhotoDemonNameAndVersion = App.Title & " " & GetPhotoDemonVersion
End Function

'Retrieve PD's current version, modified against "beta" labels, etc
Public Function GetPhotoDemonVersion() As String
    
    'Even-numbered releases are "official" releases, so simply return the full version string
    If (CLng(App.Minor) Mod 2 = 0) Then
        GetPhotoDemonVersion = App.Major & "." & App.Minor
        
    Else
    
        'Odd-numbered development releases of the pattern X.9 are production builds for the next major version, e.g. (X+1).0
        
        'Build state can be retrieved from the public const PD_BUILD_QUALITY
        Dim buildStateString As String
        
        Select Case PD_BUILD_QUALITY
        
            Case PD_PRE_ALPHA
                If g_Language Is Nothing Then
                    buildStateString = "pre-alpha"
                Else
                    buildStateString = g_Language.TranslateMessage("pre-alpha")
                End If
            
            Case PD_ALPHA
                If g_Language Is Nothing Then
                    buildStateString = "alpha"
                Else
                    buildStateString = g_Language.TranslateMessage("alpha")
                End If
            
            Case PD_BETA
                If g_Language Is Nothing Then
                    buildStateString = "beta"
                Else
                    buildStateString = g_Language.TranslateMessage("beta")
                End If
        
        End Select
        
        'Assemble a full title string, while handling the special case of .9 version numbers, which serve as production
        ' builds for the next .0 release.
        If App.Minor = 9 Then
            GetPhotoDemonVersion = CStr(App.Major + 1) & ".0 " & buildStateString & " (build " & CStr(App.Revision) & ")"
        Else
            GetPhotoDemonVersion = CStr(App.Major) & "." & CStr(App.Minor + 1) & " " & buildStateString & " (build " & CStr(App.Revision) & ")"
        End If
        
    End If
    
End Function

'Retrieve PD's current version witout any appended tags (e.g. "beta"), and with a "0" automatically plugged in for build.
Public Function GetPhotoDemonVersionCanonical() As String
    GetPhotoDemonVersionCanonical = Trim$(Str(App.Major)) & "." & Trim$(Str(App.Minor)) & ".0." & Trim$(Str(App.Revision))
End Function

'Retrieve PD's current version (not revision!) as a pure major/minor string.  This is not generally recommended for displaying
' to the user, but it's helpful for things like update checks.
Public Function GetPhotoDemonVersionMajorMinorOnly() As String
    GetPhotoDemonVersionMajorMinorOnly = Trim$(Str(App.Major)) & "." & Trim$(Str(App.Minor))
End Function

Public Function GetPhotoDemonVersionRevisionOnly() As String
    GetPhotoDemonVersionRevisionOnly = Trim$(Str(App.Revision))
End Function

'Given an arbitrary version string (e.g. "6.0.04 stability patch" or 6.0.04" or just plain "6.0"), return a canonical major/minor string, e.g. "6.0"
Public Function RetrieveVersionMajorMinorAsString(ByVal srcVersionString As String) As String

    'To avoid locale issues, replace any "," with "."
    If InStr(1, srcVersionString, ",") Then srcVersionString = Replace$(srcVersionString, ",", ".")
    
    'For this function to work, the major/minor data has to exist somewhere in the string.  Look for at least one "." occurrence.
    Dim tmpArray() As String
    tmpArray = Split(srcVersionString, ".")
    
    If UBound(tmpArray) >= 1 Then
        RetrieveVersionMajorMinorAsString = Trim$(tmpArray(0)) & "." & Trim$(tmpArray(1))
    Else
        RetrieveVersionMajorMinorAsString = ""
    End If

End Function

'Given an arbitrary version string (e.g. "6.0.04 stability patch" or 6.0.04" or just plain "6.0"), return the revision number
' as a string, e.g. 4 for "6.0.04".  If no revision is found, return 0.
Public Function RetrieveVersionRevisionAsLong(ByVal srcVersionString As String) As Long
    
    'An improperly formatted version number can cause failure; if this happens, we'll assume a revision of 0, which should
    ' force a re-download of the problematic file.
    On Error GoTo cantFormatRevisionAsLong
    
    'To avoid locale issues, replace any "," with "."
    If InStr(1, srcVersionString, ",") Then srcVersionString = Replace$(srcVersionString, ",", ".")
    
    'For this function to work, the revision has to exist somewhere in the string.  Look for at least two "." occurrences.
    Dim tmpArray() As String
    tmpArray = Split(srcVersionString, ".")
    
    If UBound(tmpArray) >= 2 Then
        RetrieveVersionRevisionAsLong = CLng(Trim$(tmpArray(2)))
    
    'If one or less "." chars are found, assume a revision of 0
    Else
        RetrieveVersionRevisionAsLong = 0
    End If
    
    Exit Function
    
cantFormatRevisionAsLong:

    RetrieveVersionRevisionAsLong = 0

End Function

'Given two version numbers, return TRUE if the second version is larger than the first.
' If the second version equals the first, FALSE is returned.
Public Function IsNewVersionHigher(ByVal oldVersion As String, ByVal newVersion As String) As Boolean
    
    'Normalize version separators
    If InStr(1, oldVersion, ",", vbBinaryCompare) Then oldVersion = Replace$(oldVersion, ",", ".")
    If InStr(1, newVersion, ",", vbBinaryCompare) Then oldVersion = Replace$(newVersion, ",", ".")
    
    'If the string representations are identical, we can exit now
    If (StrComp(oldVersion, newVersion, vbBinaryCompare) = 0) Then
        IsNewVersionHigher = False
        
    'If the strings are not equal, a more detailed comparison is required.
    Else
    
        'Parse the versions by "."
        Dim oldV() As String, newV() As String
        oldV = Split(oldVersion, ".")
        newV = Split(newVersion, ".")
        
        'Fill in any missing version entries
        Dim i As Long, oldUBound As Long
        
        If (UBound(oldV) < 3) Then
            
            oldUBound = UBound(oldV)
            ReDim Preserve oldV(0 To 3) As String
            
            For i = oldUBound + 1 To 3
                oldV(i) = "0"
            Next i
            
        End If
        
        If (UBound(newV) < 3) Then
            
            oldUBound = UBound(newV)
            ReDim Preserve newV(0 To 3) As String
            
            For i = oldUBound + 1 To 3
                newV(i) = "0"
            Next i
            
        End If
        
        'With both version numbers normalized, compare each entry in turn.
        Dim newIsNewer As Boolean
        newIsNewer = False
        
        'For each version, we will be comparing entries in turn, starting with the major version and working
        ' our way down.  We only check subsequent values if all preceding ones are equal.  (This ensures that
        ' e.g. 6.6.0 does not update to 6.5.1.)
        Dim majorIsEqual As Boolean, minorIsEqual As Boolean, revIsEqual As Boolean
                
        For i = 0 To 3
            
            Select Case i
            
                'Major version updates always trigger an update
                Case 0
                
                    If (CLng(newV(i)) > CLng(oldV(i))) Then
                        newIsNewer = True
                        Exit For
                        
                    Else
                        majorIsEqual = CBool(CLng(newV(i)) = CLng(oldV(i)))
                    End If
                
                'Minor version updates trigger an update only if the major version matches
                Case 1
                
                    If majorIsEqual Then
                        
                        If (CLng(newV(i)) > CLng(oldV(i))) Then
                            newIsNewer = True
                            Exit For
                        Else
                            minorIsEqual = CBool(CLng(newV(i)) = CLng(oldV(i)))
                        End If
                        
                    End If
                
                'Build and revision updates follow the pattern above
                Case 2
                
                    If minorIsEqual Then
                        
                        If (CLng(newV(i)) > CLng(oldV(i))) Then
                            newIsNewer = True
                            Exit For
                        Else
                            revIsEqual = CBool(CLng(newV(i)) = CLng(oldV(i)))
                        End If
                        
                    End If
                
                Case Else
                
                    If revIsEqual Then
                        newIsNewer = CBool(CLng(newV(i)) > CLng(oldV(i)))
                        Exit For
                    End If
                
            End Select
            
        Next i
        
        IsNewVersionHigher = newIsNewer
        
    End If
    
End Function

