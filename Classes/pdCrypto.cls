VERSION 1.0 CLASS
BEGIN
  MultiUse = -1  'True
  Persistable = 0  'NotPersistable
  DataBindingBehavior = 0  'vbNone
  DataSourceBehavior  = 0  'vbNone
  MTSTransactionMode  = 0  'NotAnMTSObject
END
Attribute VB_Name = "pdCrypto"
Attribute VB_GlobalNameSpace = False
Attribute VB_Creatable = True
Attribute VB_PredeclaredId = False
Attribute VB_Exposed = False
'***************************************************************************
'PhotoDemon Cryptography (and Hash) Helper Class
'Copyright 2016-2017 by Tanner Helland
'Created: 19/August/16
'Last updated: 19/August/16
'Last update: initial build; minimum functionality to replace the old cSHA256 class
'
'This class provides a variety of helper functions for performing basic crypto and hashing operations.
' WAPI does most the heavy lifting, and if you're running on XP, SP3 is required.
'
'At present, only a few default cryptographic providers are used.  This limits the crypto class to certain
' algorithms (for example, AES is not supported because it uses the specialized Microsoft AES Cryptographic Provider).
' This an easily be changed; just make sure that the various provider ID, type, and string functions are updated
' to provide all required crypto values.
'
'All source code in this file is licensed under a modified BSD license.  This means you may use the code in your own
' projects IF you provide attribution.  For more information, please visit http://photodemon.org/about/license/
'
'***************************************************************************

Option Explicit

Public Enum PD_CRYPT_PROVIDERS
    PDCP_NONE = 0
    PDCP_MS_BASE = 1
    PDCP_MS_ENH_RSA_AES = 2
    PDCP_MS_ENH_RSA_AES_XP = 3
End Enum

#If False Then
    Private Const PDCP_NONE = 0, PDCP_MS_BASE = 1, PDCP_MS_ENH_RSA_AES = 2, PDCP_MS_ENH_RSA_AES_XP = 3
#End If

Public Enum PD_CRYPT_PROVIDER_TYPE
    PDCPT_UNKNOWN = 0
    PDCPT_RSA_FULL = 1
    PDCPT_RSA_AES = 24
End Enum

#If False Then
    Private Const PDCPT_UNKNOWN = 0, PDCPT_RSA_FULL = 1, PDCPT_RSA_AES = 24
#End If

Public Enum PD_CRYPT_ALGOS
    PDCA_DES = &H6601&
    PDCA_HMAC = &H8009&
    PDCA_MAC = &H8005&
    PDCA_MD2 = &H8001&
    PDCA_MD5 = &H8003&
    PDCA_RC2 = &H6602&
    PDCA_RC4 = &H6801&
    PDCA_RSA_KEYX = &HA400&
    PDCA_RSA_SIGN = &H2400&
    PDCA_SHA = &H8004&
    PDCA_SHA1 = &H8004&
    'These SHA variants require at least XP SP3 (and on XP, they use a different crypto provider)
    PDCA_SHA_256 = &H800C&
    PDCA_SHA_384 = &H800D&
    PDCA_SHA_512 = &H800E&
End Enum

#If False Then
    Private Const PDCA_DES = &H6601, PDCA_HMAC = &H8009, PDCA_MAC = &H8005, PDCA_MD2 = &H8001, PDCA_MD5 = &H8003, PDCA_RC2 = &H6602, PDCA_RC4 = &H6801, PDCA_RSA_KEYX = &HA400
    Private Const PDCA_RSA_SIGN = &H2400, PDCA_SHA = &H8004, PDCA_SHA1 = &H8004, PDCA_SHA_256 = &H800C, PDCA_SHA_384 = &H800D, PDCA_SHA_512 = &H800E
#End If

'After data has been hashed, the result must be manually retrieved; use these values to do so
Private Enum PD_HASH_PARAMS
    PDHP_HASHVAL = 2
    PDHP_HASHSIZE = 4
End Enum

#If False Then
    Private Const PDHP_HASHVAL = 2, PDHP_HASHSIZE = 4
#End If

'Two important flags for acquiring contexts: first, we don't need specialized private keys, so we only need verify contexts.
' Also, to avoid the need for admin rights, we use machine-level key sets (as opposed to user-level ones).
Private Const CRYPT_VERIFYCONTEXT As Long = &HF0000000
Private Const CRYPT_MACHINE_KEYSET As Long = 32

'FYI: most crypto APIs return a non-zero value on success; zero on failure
Private Declare Function CryptAcquireContextW Lib "advapi32" (ByRef phProv As Long, ByVal ptrToStrContainer As Long, ByVal ptrToStrProvider As Long, ByVal dwProvType As PD_CRYPT_PROVIDER_TYPE, ByVal dwFlags As Long) As Long
Private Declare Function CryptCreateHash Lib "advapi32" (ByVal hProv As Long, ByVal algId As PD_CRYPT_ALGOS, ByVal hKey As Long, ByVal dwFlags As Long, ByRef phHash As Long) As Long
Private Declare Function CryptDestroyHash Lib "advapi32" (ByVal hHash As Long) As Long
Private Declare Function CryptGetHashParam Lib "advapi32" (ByVal hHash As Long, ByVal dwParam As PD_HASH_PARAMS, ByVal ptrToData As Long, ByRef pdwDataLen As Long, ByVal dwFlags As Long) As Long
Private Declare Function CryptHashData Lib "advapi32" (ByVal hHash As Long, ByVal ptrToData As Long, ByVal dwDataLen As Long, ByVal dwFlags As Long) As Long
Private Declare Function CryptReleaseContext Lib "advapi32" (ByVal hProv As Long, ByVal dwFlags As Long) As Long

'If a provider has been initialized, this will be non-zero.  This value *must* be released before the class exits
' (or if a new provider is required).
Private m_CryptoProviderHandle As Long, m_CryptoProviderID As PD_CRYPT_PROVIDERS

'After a hash has been created, the handle will be cached here.  If a subsequent hash takes place, this handle
' will be automatically freed.
Private m_HashHandle As Long

'PD's default string hash function.  PD uses hashed strings for a lot of random things - session IDs, temp files, etc.
' By default, the first 16 characters of an SHA-256 hash is used for these purposes.
'
'The weird "useLegacyASCIIMethod" exists because PD's past SHA-256 algorithm only took the lower 256 bits of each
' character in a VB string.  This raised the (admittedly astronomically small) possibility that two different Unicode
' strings may experience hash collisions.  Do *not* set this parameter to TRUE unless absolutely necessary, as it is
' not Unicode compatible (obviously), and it's also slower because we have to manually convert the incoming string into
' its single-byte equivalent (to get matching behavior to the old class).
Friend Function QuickHashString(ByRef srcString As String, Optional ByVal strLength As Long = 16, Optional ByVal useLegacyASCIIMethod As Boolean = False) As String
    
    If (Len(srcString) <> 0) Then
    
        Dim i As Long
            
        'Perform a quick hash of the input string
        Dim hashSuccess As Boolean
        If useLegacyASCIIMethod Then
            
            Dim tmpBytes() As Byte
            ReDim tmpBytes(0 To Len(srcString) - 1) As Byte
            
            For i = 0 To Len(srcString) - 1
                tmpBytes(i) = AscB(Mid$(srcString, i + 1, 1))
            Next i
            
            hashSuccess = QuickHash(PDCA_SHA_256, VarPtr(tmpBytes(0)), Len(srcString))
            
        Else
            hashSuccess = QuickHash(PDCA_SHA_256, StrPtr(srcString), Len(srcString) * 2)
        End If
        
        If hashSuccess Then
        
            'Retrieve the hashed data
            Dim hashBytes() As Byte, hashLength As Long
            If RetrieveHashedData(hashBytes, hashLength) Then
            
                'Translate the first (strLength) bytes into a human-readable string, then return it.
                ' (Thank you to vbForums user "dilettante" for this translation technique.)
                QuickHashString = String$(strLength, "0")
                
                For i = 0 To (strLength \ 2) - 1
                    If (hashBytes(i) < &H10) Then
                        Mid$(QuickHashString, i * 2 + 2, 1) = Hex$(hashBytes(i))
                    Else
                        Mid$(QuickHashString, i * 2 + 1, 2) = Hex$(hashBytes(i))
                    End If
                Next i
                
                QuickHashString = LCase$(QuickHashString)
                
            End If
            
        End If
    
    Else
        QuickHashString = vbNullString
    End If
    
End Function

'Shortcut function to perform a full hash of some input data.  This function does *not* support appending;
' the existing hash, if any, will be freed prior to hashing the new data.
Friend Function QuickHash(ByVal hashAlgorithm As PD_CRYPT_ALGOS, ByVal ptrToSrcBytes As Long, ByVal lenOfBytes As Long) As Boolean

    'Always start by creating a new provider
    If CreateProvider(hashAlgorithm) Then
    
        'Next, create a matching hash object
        If (m_HashHandle <> 0) Then FreeCurrentHash
        If CBool(CryptCreateHash(m_CryptoProviderHandle, hashAlgorithm, 0&, 0&, m_HashHandle) <> 0) Then
            If (m_HashHandle <> 0) Then
            
                'Attempt to hash the data
                QuickHash = CBool(CryptHashData(m_HashHandle, ptrToSrcBytes, lenOfBytes, 0&) <> 0)
                If (Not QuickHash) Then InternalCryptError "QuickHash", "Hash creation successful, but actual hash failed."
                
                'Note that hashes do not return the actual data; that's maintained internally (which is nice as
                ' you can append data without worrying about buffering).
                
                'To see the hashed result, use the dedicated hash retrieval function(s).
                
            Else
                InternalCryptError "QuickHash", "Hash creation succeeded, but hash handle is still zero"
                QuickHash = False
            End If
        Else
            InternalCryptError "QuickHash", "Hash creation failed"
            QuickHash = False
        End If
    
    Else
        InternalCryptError "QuickHash", "Provider creation failed"
        QuickHash = False
    End If

End Function

'Important note on this function: if the destination array is already large enough to hold the data, it *will not*
' be resized.  You *must* peek at the data length value and use that, instead of the UBound of the array.
Friend Function RetrieveHashedData(ByRef dstBytes() As Byte, ByRef dataLength As Long) As Boolean
    
    If (m_HashHandle <> 0) Then
        
        'Start by retrieving the size of the hashed data
        Dim hashPtrLength As Long
        hashPtrLength = 4
        
        If (CryptGetHashParam(m_HashHandle, PDHP_HASHSIZE, VarPtr(dataLength), hashPtrLength, 0&) <> 0) Then
            
            'Prep the destination array
            If VB_Hacks.IsArrayInitialized(dstBytes) Then
                If (UBound(dstBytes) < dataLength - 1) Then ReDim dstBytes(0 To dataLength - 1) As Byte
            Else
                ReDim dstBytes(0 To dataLength - 1) As Byte
            End If
            
            'Retrieve the hashed data
            If (CryptGetHashParam(m_HashHandle, PDHP_HASHVAL, VarPtr(dstBytes(LBound(dstBytes))), dataLength, 0&) <> 0) Then
                RetrieveHashedData = True
            Else
                InternalCryptError "RetrieveHashedData", "Couldn't retrieve hashed data"
                RetrieveHashedData = False
            End If
            
        Else
            InternalCryptError "RetrieveHashedData", "Couldn't retrieve hash size"
            RetrieveHashedData = False
        End If
        
    Else
        InternalCryptError "RetrieveHashedData", "Hash object doesn't exist"
        RetrieveHashedData = False
    End If
    
End Function

'Retrieve a provider capable of using the specified hash algorithm.  At present, this class only supports a
' handful of default MS providers; as a result, it will reuse previous providers (when possible) instead of
' requesting new ones.
Private Function CreateProvider(ByVal hashAlgorithm As PD_CRYPT_ALGOS) As Boolean
    
    'Figure out the provider required for this algorithm
    Dim providerID As PD_CRYPT_PROVIDERS, strProvider As String
    providerID = MatchProviderToAlgo(hashAlgorithm)
    strProvider = GetProviderString(providerID)
    
    'Do not proceed if the provider type is unknown
    If ((providerID <> PDCP_NONE) And (Len(strProvider) <> 0)) Then
    
        'See if the current provider matches the previously created one (if any); if it does, we can re-use
        ' the current provider handle for a performance boost.
        If ((m_CryptoProviderHandle = 0) Or (providerID <> m_CryptoProviderID)) Then
            
            'Free the previous provider, if any
            If (m_CryptoProviderHandle <> 0) Then FreeCurrentProvider
            m_CryptoProviderID = GetProviderType(providerID)
            CreateProvider = CBool(CryptAcquireContextW(m_CryptoProviderHandle, 0&, StrPtr(strProvider), m_CryptoProviderID, CRYPT_VERIFYCONTEXT Or CRYPT_MACHINE_KEYSET) <> 0)
            
        Else
            CreateProvider = True
        End If
    Else
        CreateProvider = False
    End If
                
End Function

Private Function MatchProviderToAlgo(ByVal srcAlgorithm As PD_CRYPT_ALGOS) As PD_CRYPT_PROVIDERS

    Select Case srcAlgorithm
        
        'Certain SHA algorithms require an OS version check, because they use a specialized provider under XP
        Case PDCA_SHA_256, PDCA_SHA_384, PDCA_SHA_512
            If g_IsVistaOrLater Then
                MatchProviderToAlgo = PDCP_MS_ENH_RSA_AES
            Else
                MatchProviderToAlgo = PDCP_MS_ENH_RSA_AES_XP
            End If
        
        'For any other algorithm, assume the default MS base provider
        Case Else
            MatchProviderToAlgo = PDCP_MS_BASE
    
    End Select
    
End Function

Private Function GetProviderType(ByVal srcProvider As PD_CRYPT_PROVIDERS) As PD_CRYPT_PROVIDER_TYPE
    Select Case srcProvider
        Case PDCP_MS_BASE
            GetProviderType = PDCPT_RSA_FULL
        Case PDCP_MS_ENH_RSA_AES, PDCP_MS_ENH_RSA_AES_XP
            GetProviderType = PDCPT_RSA_AES
        Case Else
            GetProviderType = PDCPT_UNKNOWN
    End Select
End Function

'Retrieve a string version of a given provider type.  Note that the function will return a null string if a
' provider is unsupported (e.g. providerType = PDCP_NONE); the caller needs to handle this case and fail gracefully.
Private Function GetProviderString(Optional ByVal providerType As PD_CRYPT_PROVIDERS = PDCP_NONE) As String
    
    Select Case providerType
    
        Case PDCP_MS_BASE
            GetProviderString = "Microsoft Base Cryptographic Provider v1.0"
        
        Case PDCP_MS_ENH_RSA_AES
            GetProviderString = "Microsoft Enhanced RSA and AES Cryptographic Provider"
        
        Case PDCP_MS_ENH_RSA_AES_XP
            GetProviderString = "Microsoft Enhanced RSA and AES Cryptographic Provider (Prototype)"
        
        Case Else
            GetProviderString = vbNullString
        
    End Select
    
End Function

'Free the current hash.  Make sure you retrieve any desired hash data prior to freeing it, as this class does
' not perform any manual caching!
Private Function FreeCurrentHash() As Boolean
    If (m_HashHandle <> 0) Then
        FreeCurrentHash = CBool(CryptDestroyHash(m_HashHandle) <> 0)
        m_HashHandle = 0
    Else
        FreeCurrentHash = True
    End If
End Function

'Free the current provider.  Do not attempt to perform crypto tasks until a new provider is acquired.  (This happens
' automatically for most class functions.)
Private Function FreeCurrentProvider() As Boolean
    If (m_CryptoProviderHandle <> 0) Then
        FreeCurrentProvider = CBool(CryptReleaseContext(m_CryptoProviderHandle, 0&) <> 0)
        m_CryptoProviderHandle = 0
    Else
        FreeCurrentProvider = True
    End If
End Function

Private Sub InternalCryptError(ByVal funcName As String, ByVal errName As String, Optional ByVal errDescription As String = vbNullString)
    #If DEBUGMODE = 1 Then
        Dim errString As String
        errString = "WARNING!  pdCrypto error in " & funcName & ": " & errName
        If (Len(errDescription) <> 0) Then
            errString = errString & " - " & errDescription
        Else
            errString = errString & " (FYI, last DLL error is #" & Err.LastDllError & ")"
        End If
        pdDebug.LogAction errString
    #End If
End Sub

Private Sub Class_Initialize()
    m_CryptoProviderHandle = 0
    m_CryptoProviderID = PDCP_NONE
End Sub

Private Sub Class_Terminate()
    FreeCurrentHash
    FreeCurrentProvider
End Sub
