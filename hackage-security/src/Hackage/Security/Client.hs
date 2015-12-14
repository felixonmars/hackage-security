{-# LANGUAGE CPP #-}
#if __GLASGOW_HASKELL__ >= 710
{-# LANGUAGE StaticPointers #-}
#endif
-- | Main entry point into the Hackage Security framework for clients
module Hackage.Security.Client (
    -- * Checking for updates
    checkForUpdates
  , HasUpdates(..)
    -- * Downloading targets
  , downloadPackage
  , downloadPackage'
    -- * Access to the Hackage index
  , Directory      -- opaque
  , DirectoryEntry -- opaque
  , IndexFile(..)
  , directoryEntries
  , directoryLookup
  , getDirectory
  , withIndex
    -- * Bootstrapping
  , requiresBootstrap
  , bootstrap
    -- * Re-exports
  , module Hackage.Security.TUF
  , module Hackage.Security.Key
    -- ** We only a few bits from .Repository
    -- TODO: Maybe this is a sign that these should be in a different module?
  , Repository -- opaque
  , DownloadedFile(..)
  , SomeRemoteError(..)
  , LogMessage(..)
    -- * Exceptions
  , uncheckClientErrors
  , VerificationError(..)
  , VerificationHistory
  , RootUpdated(..)
  , InvalidPackageException(..)
  , InvalidFileInIndex(..)
  , LocalFileCorrupted(..)
  ) where

import Prelude hiding (log)
import Control.Exception
import Control.Monad
import Control.Monad.IO.Class
import Data.Maybe (isNothing)
import Data.Time
import Data.Traversable (for)
import Data.Typeable (Typeable)
import qualified Codec.Archive.Tar       as Tar
import qualified Codec.Archive.Tar.Index as Tar
import qualified Data.ByteString.Lazy    as BS.L

import Distribution.Package (PackageIdentifier)
import Distribution.Text (display)

import Hackage.Security.Client.Formats
import Hackage.Security.Client.Repository
import Hackage.Security.Client.Verify
import Hackage.Security.JSON
import Hackage.Security.Key
import Hackage.Security.Key.Env (KeyEnv)
import Hackage.Security.Trusted
import Hackage.Security.Trusted.TCB
import Hackage.Security.TUF
import Hackage.Security.Util.Checked
import Hackage.Security.Util.Path
import Hackage.Security.Util.Pretty
import Hackage.Security.Util.Some
import Hackage.Security.Util.Stack
import qualified Hackage.Security.Key.Env   as KeyEnv

{-------------------------------------------------------------------------------
  Checking for updates
-------------------------------------------------------------------------------}

data HasUpdates = HasUpdates | NoUpdates
  deriving (Show, Eq, Ord)

-- | Generic logic for checking if there are updates
--
-- This implements the logic described in Section 5.1, "The client application",
-- of the TUF spec. It checks which of the server metadata has changed, and
-- downloads all changed metadata to the local cache. (Metadata here refers
-- both to the TUF security metadata as well as the Hackage packge index.)
--
-- You should pass @Nothing@ for the UTCTime _only_ under exceptional
-- circumstances (such as when the main server is down for longer than the
-- expiry dates used in the timestamp files on mirrors).
checkForUpdates :: (Throws VerificationError, Throws SomeRemoteError)
                => Repository down
                -> Maybe UTCTime -- ^ To check expiry times against (if using)
                -> IO HasUpdates
checkForUpdates rep@Repository{..} mNow =
    withMirror rep $ limitIterations []
  where
    -- More or less randomly chosen maximum iterations
    -- See <https://github.com/theupdateframework/tuf/issues/287>.
    maxNumIterations :: Int
    maxNumIterations = 5

    -- The spec stipulates that on a verification error we must download new
    -- root information and start over. However, in order to prevent DoS attacks
    -- we limit how often we go round this loop.
    -- See als <https://github.com/theupdateframework/tuf/issues/287>.
    limitIterations :: (Throws VerificationError, Throws SomeRemoteError)
                    => VerificationHistory -> IO HasUpdates
    limitIterations history | length history >= maxNumIterations =
        throwChecked $ VerificationErrorLoop (reverse history)
    limitIterations history = do
        -- Get all cached info
        --
        -- NOTE: Although we don't normally update any cached files until the
        -- whole verification process successfully completes, in case of a
        -- verification error, or in case of a regular update of the root info,
        -- we DO update the local files. Hence, we must re-read all local files
        -- on each iteration.
        cachedInfo <- getCachedInfo rep

        mHasUpdates <- tryChecked -- catch RootUpdated
                     $ tryChecked -- catch VerificationError
                     $ runVerify repLockCache
                     $ go attemptNr cachedInfo
        case mHasUpdates of
          Left ex -> do
            -- NOTE: This call to updateRoot is not itself protected by an
            -- exception handler, and may therefore throw a VerificationError.
            -- This is intentional: if we get verification errors during the
            -- update process, _and_ we cannot update the main root info, then
            -- we cannot do anything.
            log rep $ LogVerificationError ex
            let history'   = Right ex : history
                attemptNr' = attemptNr + 1
            updateRoot rep mNow attemptNr' cachedInfo (Left ex)
            limitIterations history'
          Right (Left RootUpdated) -> do
            log rep $ LogRootUpdated
            let history' = Left RootUpdated : history
            limitIterations history'
          Right (Right hasUpdates) ->
            return hasUpdates
      where
        attemptNr :: AttemptNr
        attemptNr = fromIntegral $ length history

    -- The 'Verify' monad only caches the downloaded files after verification.
    -- See also <https://github.com/theupdateframework/tuf/issues/283>.
    go :: Throws RootUpdated => AttemptNr -> CachedInfo -> Verify HasUpdates
    go attemptNr cachedInfo@CachedInfo{..} = do
      -- Get the new timestamp
      newTS <- getRemoteFile' RemoteTimestamp
      let newInfoSS = static timestampInfoSnapshot <$$> newTS

      -- Check if the snapshot has changed
      if not (fileChanged cachedInfoSnapshot newInfoSS)
        then return NoUpdates
        else do
          -- Get the new snapshot
          newSS <- getRemoteFile' (RemoteSnapshot newInfoSS)
          let newInfoRoot    = static snapshotInfoRoot    <$$> newSS
              newInfoMirrors = static snapshotInfoMirrors <$$> newSS
              newInfoTarGz   = static snapshotInfoTarGz   <$$> newSS
              mNewInfoTar    = trustElems (static snapshotInfoTar <$$> newSS)

          -- If root metadata changed, download and restart
          when (rootChanged cachedInfoRoot newInfoRoot) $ liftIO $ do
            updateRoot rep mNow attemptNr cachedInfo (Right newInfoRoot)
            -- By throwing 'RootUpdated' as an exception we make sure that
            -- any files previously downloaded (to temporary locations)
            -- will not be cached.
            throwChecked RootUpdated

          -- If mirrors changed, download and verify
          when (fileChanged cachedInfoMirrors newInfoMirrors) $
            newMirrors =<< getRemoteFile' (RemoteMirrors newInfoMirrors)

          -- If index changed, download and verify
          when (fileChanged cachedInfoTarGz newInfoTarGz) $
            updateIndex newInfoTarGz mNewInfoTar

          return HasUpdates
      where
        getRemoteFile' :: ( VerifyRole a
                          , FromJSON ReadJSON_Keys_Layout (Signed a)
                          )
                       => RemoteFile (f :- ()) Metadata -> Verify (Trusted a)
        getRemoteFile' = liftM fst . getRemoteFile rep cachedInfo attemptNr mNow

        -- Update the index and check against the appropriate hash
        updateIndex :: Trusted FileInfo         -- info about @.tar.gz@
                    -> Maybe (Trusted FileInfo) -- info about @.tar@
                    -> Verify ()
        updateIndex newInfoTarGz Nothing = do
          (targetPath, tempPath) <- getRemote' rep attemptNr $
            RemoteIndex (HFZ FGz) (FsGz newInfoTarGz)
          verifyFileInfo' (Just newInfoTarGz) targetPath tempPath
        updateIndex newInfoTarGz (Just newInfoTar) = do
          (format, targetPath, tempPath) <- getRemote rep attemptNr $
            RemoteIndex (HFS (HFZ FGz)) (FsUnGz newInfoTar newInfoTarGz)
          case format of
            Some FGz -> verifyFileInfo' (Just newInfoTarGz) targetPath tempPath
            Some FUn -> verifyFileInfo' (Just newInfoTar)   targetPath tempPath

    -- Unlike for other files, if we didn't have an old snapshot, consider the
    -- root info unchanged (otherwise we would loop indefinitely).
    -- See also <https://github.com/theupdateframework/tuf/issues/286>
    rootChanged :: Maybe (Trusted FileInfo) -> Trusted FileInfo -> Bool
    rootChanged Nothing    _   = False
    rootChanged (Just old) new = not (trustedFileInfoEqual old new)

    -- For any file other than the root we consider the file to have changed
    -- if we do not yet have a local snapshot to tell us the old info.
    fileChanged :: Maybe (Trusted FileInfo) -> Trusted FileInfo -> Bool
    fileChanged Nothing    _   = True
    fileChanged (Just old) new = not (trustedFileInfoEqual old new)

    -- We don't actually _do_ anything with the mirrors file until the next call
    -- to 'checkUpdates', because we want to use a single server for a single
    -- check-for-updates request. If validation was successful the repository
    -- will have cached the mirrors file and it will be available on the next
    -- request.
    newMirrors :: Trusted Mirrors -> Verify ()
    newMirrors _ = return ()

-- | Update the root metadata
--
-- Note that the new root metadata is verified using the old root metadata,
-- and only then trusted.
--
-- We don't always have root file information available. If we notice during
-- the normal update process that the root information has changed then the
-- snapshot will give us the new file information; but if we need to update
-- the root information due to a verification error we do not.
--
-- We additionally delete the cached cached snapshot and timestamp. This is
-- necessary for two reasons:
--
-- 1. If during the normal update process we notice that the root info was
--    updated (because the hash of @root.json@ in the new snapshot is different
--    from the old snapshot) we download new root info and start over, without
--    (yet) downloading a (potential) new index. This means it is important that
--    we not overwrite our local cached snapshot, because if we did we would
--    then on the next iteration conclude there were no updates and we would
--    fail to notice that we should have updated the index. However, unless we
--    do something, this means that we would conclude on the next iteration once
--    again that the root info has changed (because the hash in the new shapshot
--    still doesn't match the hash in the cached snapshot), and we would loop
--    until we throw a 'VerificationErrorLoop' exception. By deleting the local
--    snapshot we basically reset the client to its initial state, and we will
--    not try to download the root info once again. The only downside of this is
--    that we will also re-download the index after every root info change.
--    However, this should be infrequent enough that this isn't an issue.
--    See also <https://github.com/theupdateframework/tuf/issues/285>.
--
-- 2. Additionally, deleting the local timestamp and snapshot protects against
--    an attack where an attacker has set the file version of the snapshot or
--    timestamp to MAX_INT, thereby making further updates impossible.
--    (Such an attack would require a timestamp/snapshot key compromise.)
--
-- However, we _ONLY_ do this when the root information has actually changed.
-- If we did this unconditionally it would mean that we delete the locally
-- cached timestamp whenever the version on the remote timestamp is invalid,
-- thereby rendering the file version on the timestamp and the snapshot useless.
-- See <https://github.com/theupdateframework/tuf/issues/283#issuecomment-115739521>
updateRoot :: (Throws VerificationError, Throws SomeRemoteError)
           => Repository down
           -> Maybe UTCTime
           -> AttemptNr
           -> CachedInfo
           -> Either VerificationError (Trusted FileInfo)
           -> IO ()
updateRoot rep@Repository{..} mNow isRetry cachedInfo eFileInfo = do
    rootReallyChanged <- runVerify repLockCache $ do
      (_newRoot :: Trusted Root, rootTempFile) <- getRemoteFile
        rep
        cachedInfo
        isRetry
        mNow
        (RemoteRoot (eitherToMaybe eFileInfo))

      -- NOTE: It is important that we do this check within the evalContT,
      -- because the temporary file will be deleted once we leave its scope.
      case eFileInfo of
        Right _ ->
          -- We are downloading the root info because the hash in the snapshot
          -- changed. In this case the root definitely changed.
          return True
        Left _e -> liftIO $ do
          -- We are downloading the root because of a verification error. In
          -- this case the root info may or may not have changed. In most cases
          -- it would suffice to compare the file version now; however, in the
          -- (exceptional) circumstance where the root info has changed but
          -- the file version has not, this would result in the same infinite
          -- loop described above. Hence, we must compare file hashes, and they
          -- must be computed on the raw file, not the parsed file.
          oldRootFile <- repGetCachedRoot
          oldRootInfo <- DeclareTrusted <$> computeFileInfo oldRootFile
          not <$> downloadedVerify rootTempFile oldRootInfo

    when rootReallyChanged $ clearCache rep

{-------------------------------------------------------------------------------
  Convenience functions for downloading and parsing various files
-------------------------------------------------------------------------------}

data CachedInfo = CachedInfo {
    cachedRoot         :: Trusted Root
  , cachedKeyEnv       :: KeyEnv
  , cachedTimestamp    :: Maybe (Trusted Timestamp)
  , cachedSnapshot     :: Maybe (Trusted Snapshot)
  , cachedMirrors      :: Maybe (Trusted Mirrors)
  , cachedInfoSnapshot :: Maybe (Trusted FileInfo)
  , cachedInfoRoot     :: Maybe (Trusted FileInfo)
  , cachedInfoMirrors  :: Maybe (Trusted FileInfo)
  , cachedInfoTarGz    :: Maybe (Trusted FileInfo)
  }

cachedVersion :: CachedInfo -> RemoteFile fs typ -> Maybe FileVersion
cachedVersion CachedInfo{..} remoteFile =
    case mustCache remoteFile of
      CacheAs CachedTimestamp -> timestampVersion . trusted <$> cachedTimestamp
      CacheAs CachedSnapshot  -> snapshotVersion  . trusted <$> cachedSnapshot
      CacheAs CachedMirrors   -> mirrorsVersion   . trusted <$> cachedMirrors
      CacheAs CachedRoot      -> Just . rootVersion . trusted $ cachedRoot
      CacheIndex -> Nothing
      DontCache  -> Nothing

-- | Get all cached info (if any)
getCachedInfo :: (Applicative m, MonadIO m) => Repository down -> m CachedInfo
getCachedInfo rep = do
    (cachedRoot, cachedKeyEnv) <- readLocalRoot rep
    cachedTimestamp <- readLocalFile rep cachedKeyEnv CachedTimestamp
    cachedSnapshot  <- readLocalFile rep cachedKeyEnv CachedSnapshot
    cachedMirrors   <- readLocalFile rep cachedKeyEnv CachedMirrors

    let cachedInfoSnapshot = fmap (static timestampInfoSnapshot <$$>) cachedTimestamp
        cachedInfoRoot     = fmap (static snapshotInfoRoot      <$$>) cachedSnapshot
        cachedInfoMirrors  = fmap (static snapshotInfoMirrors   <$$>) cachedSnapshot
        cachedInfoTarGz    = fmap (static snapshotInfoTarGz     <$$>) cachedSnapshot

    return CachedInfo{..}

readLocalRoot :: MonadIO m => Repository down -> m (Trusted Root, KeyEnv)
readLocalRoot rep = do
    cachedPath <- liftIO $ repGetCachedRoot rep
    signedRoot <- throwErrorsUnchecked LocalFileCorrupted =<<
                    readCachedJSON rep KeyEnv.empty cachedPath
    return (trustLocalFile signedRoot, rootKeys (signed signedRoot))

readLocalFile :: ( FromJSON ReadJSON_Keys_Layout (Signed a)
                 , MonadIO m, Applicative m
                 )
              => Repository down -> KeyEnv -> CachedFile -> m (Maybe (Trusted a))
readLocalFile rep cachedKeyEnv file = do
    mCachedPath <- liftIO $ repGetCached rep file
    for mCachedPath $ \cachedPath -> do
      signed <- throwErrorsUnchecked LocalFileCorrupted =<<
                  readCachedJSON rep cachedKeyEnv cachedPath
      return $ trustLocalFile signed

getRemoteFile :: ( Throws VerificationError
                 , Throws SomeRemoteError
                 , VerifyRole a
                 , FromJSON ReadJSON_Keys_Layout (Signed a)
                 )
              => Repository down
              -> CachedInfo
              -> AttemptNr
              -> Maybe UTCTime
              -> RemoteFile (f :- ()) Metadata
              -> Verify (Trusted a, down Metadata)
getRemoteFile rep@Repository{..} cachedInfo@CachedInfo{..} isRetry mNow file = do
    (targetPath, tempPath) <- getRemote' rep isRetry file
    verifyFileInfo' (remoteFileDefaultInfo file) targetPath tempPath
    signed   <- throwErrorsChecked (VerificationErrorDeserialization targetPath) =<<
                  readDownloadedJSON rep cachedKeyEnv tempPath
    verified <- throwErrorsChecked id $ verifyRole
                  cachedRoot
                  targetPath
                  (cachedVersion cachedInfo file)
                  mNow
                  signed
    return (trustVerified verified, tempPath)

{-------------------------------------------------------------------------------
  Downloading target files
-------------------------------------------------------------------------------}

-- | Download a package
downloadPackage :: ( Throws SomeRemoteError
                   , Throws VerificationError
                   , Throws InvalidPackageException
                   )
                => Repository down    -- ^ Repository
                -> PackageIdentifier  -- ^ Package to download
                -> AbsolutePath       -- ^ Destination (see also 'downloadPackage'')
                -> IO ()
downloadPackage rep@Repository{..} pkgId dest = withMirror rep $ runVerify repLockCache $ do
    -- We need the cached root information in order to resolve key IDs and
    -- verify signatures. Note that whenever we read a JSON file, we verify
    -- signatures (even if we don't verify the keys); if this is a problem
    -- (for performance) we need to parameterize parseJSON.
    (_cachedRoot, keyEnv) <- readLocalRoot rep

    -- NOTE: The files inside the index as evaluated lazily.
    --
    -- 1. The index tarball contains delegated target.json files for both
    --    unsigned and signed packages. We need to verify the signatures of all
    --    signed metadata (that is: the metadata for signed packages).
    --
    -- 2. Since the tarball also contains the .cabal files, we should also
    --    verify the hashes of those .cabal files against the hashes recorded in
    --    signed metadata (there is no point comparing against hashes recorded
    --    in unsigned metadata because attackers could just change those).
    --
    -- Since we don't have author signing yet, we don't have any additional
    -- signed metadata and therefore we currently don't have to do anything
    -- here.
    --
    -- TODO: If we have explicit, author-signed, lists of versions for a package
    -- (as described in @README.md@), then evaluating these "middle-level"
    -- delegation files lazily opens us up to a rollback attack: if we've never
    -- downloaded the delegations for a package before, then we have nothing to
    -- compare the version number in the file that we downloaded against. One
    -- option is to always download and verify all these middle level files
    -- (strictly); other is to include the version number of all of these files
    -- in the snapshot. This is described in more detail in
    -- <https://github.com/theupdateframework/tuf/issues/282#issuecomment-102468421>.
    let trustIndex :: Signed a -> Trusted a
        trustIndex = trustLocalFile

    -- Get the metadata (from the previously updated index)
    --
    -- NOTE: Currently we hardcode the location of the package specific
    -- metadata. By rights we should read the global targets file and apply the
    -- delegation rules. Until we have author signing however this is
    -- unnecessary.
    targets :: Trusted Targets <- do
      let indexFile = IndexPkgMetadata pkgId
      mRaw <- getFromIndex rep indexFile
      case mRaw of
        Nothing -> liftIO $ throwChecked $ InvalidPackageException pkgId
        Just raw -> do
          signed <- throwErrorsUnchecked (InvalidFileInIndex indexFile) $
                      parseJSON_Keys_NoLayout keyEnv raw
          return $ trustIndex signed

    -- The path of the package, relative to the targets.json file
    let filePath :: TargetPath
        filePath = TargetPathRepo $ repoLayoutPkgTarGz repLayout pkgId

    let mTargetMetaData :: Maybe (Trusted FileInfo)
        mTargetMetaData = trustElems
                        $ trustStatic (static targetsLookup)
             `trustApply` DeclareTrusted filePath
             `trustApply` targets
    targetMetaData :: Trusted FileInfo
      <- case mTargetMetaData of
           Nothing -> liftIO $
             throwChecked $ VerificationErrorUnknownTarget filePath
           Just nfo ->
             return nfo

    -- TODO: should we check if cached package available? (spec says no)
    tarGz <- do
      (targetPath, downloaded) <- getRemote' rep (AttemptNr 0) $
        RemotePkgTarGz pkgId targetMetaData
      verifyFileInfo' (Just targetMetaData) targetPath downloaded
      return downloaded

    -- If all checks succeed, copy file to its target location.
    liftIO $ downloadedCopyTo tarGz dest

-- | Variation on 'downloadPackage' that takes a FilePath instead.
downloadPackage' :: ( Throws SomeRemoteError
                   , Throws VerificationError
                   , Throws InvalidPackageException
                   )
                 => Repository down    -- ^ Repository
                 -> PackageIdentifier  -- ^ Package to download
                 -> FilePath           -- ^ Destination
                 -> IO ()
downloadPackage' rep pkgId dest =
    downloadPackage rep pkgId =<< makeAbsolute (fromFilePath dest)

{-------------------------------------------------------------------------------
  Access to the tar index
-------------------------------------------------------------------------------}

-- | (Abstract) directory into the Hackage index providing efficient lookups.
newtype Directory = Directory Tar.TarIndex

-- | (Abstract) entry into the Hackage index.
--
-- See 'directoryLookup' or 'directoryEntries' to obtain a 'IndexEntry', or
-- 'indexLookup' to lookup retrieve an entry from the index
newtype DirectoryEntry = DirectoryEntry Tar.TarEntryOffset
  deriving (Eq, Ord)

-- | Do a directory lookup
--
-- This is an efficient operation
directoryLookup :: Repository down
                -> Directory
                -> IndexFile
                -> Maybe DirectoryEntry
directoryLookup Repository{..} (Directory idx) =
    liftM mkEntry . Tar.lookup idx . path
  where
    path :: IndexFile -> FilePath
    path = toUnrootedFilePath
         . unrootPath'
         . indexFileToPath (repoIndexLayout repLayout)

    mkEntry :: Tar.TarIndexEntry -> DirectoryEntry
    mkEntry (Tar.TarFileEntry offset) = DirectoryEntry offset
    mkEntry (Tar.TarDir _) = error "directoryLookup: unexpected directory"

-- | The first and next-available 'DirectoryEntry' for the index
--
-- This is useful for clients who wish to enumerate the entries in the index.
-- Clients who wish to do their own incremental updates can cache this range;
-- the cached next-available index can then be used as the starting point for
-- enumerating the new entries.
directoryEntries :: Directory -> (DirectoryEntry, DirectoryEntry)
directoryEntries (Directory idx) = (
      DirectoryEntry $ 0
    , DirectoryEntry $ Tar.indexEndEntryOffset idx
    )

-- | Read the Hackage index directory
--
-- Should only be called after 'checkForUpdates'.
getDirectory :: Repository down -> IO Directory
getDirectory = liftM Directory . repGetIndexIdx

-- | Look up an entry in the Hackage index
--
-- This is in 'withFile' style so that clients can efficiently look up multiple
-- files from the index. The callback is provided with the index path to the
-- file corresponding to the directory entry as well as the file contents and
-- the 'DirectoryEntry' of the next file. If the 'DirectoryEntry' points past
-- the end of the file the callback is given 'Nothing'.
--
-- In principle this will do verification (once we have implemented author
-- signing). Right now it doesn't need to do that, because the index as a whole
-- will have been verified.
--
-- Should only be called after 'checkForUpdates'.
withIndex :: Repository down
          -> ((DirectoryEntry -> IO (Maybe (IndexFile, BS.L.ByteString, DirectoryEntry))) -> IO a)
          -> IO a
withIndex Repository{..} callback =
    repWithIndex $ callback . lookupEntry
  where
    lookupEntry :: Handle
                -> DirectoryEntry
                -> IO (Maybe (IndexFile, BS.L.ByteString, DirectoryEntry))
    lookupEntry h (DirectoryEntry offset) = do
      mEntry <- Tar.hReadEntryHeaderOrEof h offset
      case mEntry of
        Nothing -> return Nothing
        Just (entry, next) ->
          case Tar.entryContent entry of
            Tar.NormalFile _bs sz -> do
              -- hReadEntryHeaderOrEof didn't actually read the contents
              Tar.hSeekEntryContentOffset h offset
              content <- BS.L.hGet h (fromIntegral sz)
              return $ Just (
                  parse (Tar.entryPath entry)
                , content
                , DirectoryEntry next
                )
            _otherEntryType ->
              throwIO $ userError "withIndex: unexpected entry"

    parse :: FilePath -> IndexFile
    parse fp = case indexFileFromPath (repoIndexLayout repLayout) fp of
                 Nothing -> error $ "Unrecognized path " ++ fp
                 Just ip -> ip

{-------------------------------------------------------------------------------
  Bootstrapping
-------------------------------------------------------------------------------}

-- | Check if we need to bootstrap (i.e., if we have root info)
requiresBootstrap :: Repository down -> IO Bool
requiresBootstrap rep = isNothing <$> repGetCached rep CachedRoot

-- | Bootstrap the chain of trust
--
-- New clients might need to obtain a copy of the root metadata. This however
-- represents a chicken-and-egg problem: how can we verify the root metadata
-- we downloaded? The only possibility is to be provided with a set of an
-- out-of-band set of root keys and an appropriate threshold.
--
-- Clients who provide a threshold of 0 can do an initial "unsafe" update
-- of the root information, if they wish.
--
-- The downloaded root information will _only_ be verified against the
-- provided keys, and _not_ against previously downloaded root info (if any).
-- It is the responsibility of the client to call `bootstrap` only when this
-- is the desired behaviour.
bootstrap :: (Throws SomeRemoteError, Throws VerificationError)
          => Repository down -> [KeyId] -> KeyThreshold -> IO ()
bootstrap rep@Repository{..} trustedRootKeys keyThreshold = withMirror rep $ runVerify repLockCache $ do
    _newRoot :: Trusted Root <- do
      (targetPath, tempPath) <- getRemote' rep (AttemptNr 0) (RemoteRoot Nothing)
      signed   <- throwErrorsChecked (VerificationErrorDeserialization targetPath) =<<
                    readDownloadedJSON rep KeyEnv.empty tempPath
      verified <- throwErrorsChecked id $ verifyFingerprints
                    trustedRootKeys
                    keyThreshold
                    targetPath
                    signed
      return $ trustVerified verified

    clearCache rep

{-------------------------------------------------------------------------------
  Wrapper around the Repository functions
-------------------------------------------------------------------------------}

getRemote :: forall fs down typ. Throws SomeRemoteError
          => Repository down
          -> AttemptNr
          -> RemoteFile fs typ
          -> Verify (Some Format, TargetPath, down typ)
getRemote r attemptNr file = do
    (Some format, downloaded) <- repGetRemote r attemptNr file
    let targetPath = TargetPathRepo $ remoteRepoPath' (repLayout r) file format
    return (Some (hasFormatGet format), targetPath, downloaded)

-- | Variation on getRemote where we only expect one type of result
getRemote' :: forall f down typ. Throws SomeRemoteError
           => Repository down
           -> AttemptNr
           -> RemoteFile (f :- ()) typ
           -> Verify (TargetPath, down typ)
getRemote' r isRetry file = ignoreFormat <$> getRemote r isRetry file
  where
    ignoreFormat (_format, targetPath, tempPath) = (targetPath, tempPath)

clearCache :: MonadIO m => Repository down -> m ()
clearCache r = liftIO $ repClearCache r

log :: MonadIO m => Repository down -> LogMessage -> m ()
log r msg = liftIO $ repLog r msg

-- | Get a single file from the index
getFromIndex :: MonadIO m
             => Repository down
             -> IndexFile
             -> m (Maybe BS.L.ByteString)
getFromIndex r file = liftIO $ do
    dir <- getDirectory r
    case directoryLookup r dir file of
      Nothing    -> return Nothing
      Just entry -> fmap aux <$> withIndex r ($ entry)
  where
    aux :: (IndexFile, BS.L.ByteString, DirectoryEntry) -> BS.L.ByteString
    aux (_file, bs, _next) = bs

-- Tries to load the cached mirrors file
withMirror :: Repository down -> IO a -> IO a
withMirror rep callback = do
    mMirrors <- repGetCached rep CachedMirrors
    mirrors  <- case mMirrors of
      Nothing -> return Nothing
      Just fp -> filterMirrors <$>
                   (throwErrorsUnchecked LocalFileCorrupted =<<
                     readJSON_NoKeys_NoLayout fp)
    repWithMirror rep mirrors $ callback
  where
    filterMirrors :: UninterpretedSignatures Mirrors -> Maybe [Mirror]
    filterMirrors = Just
                  . filter (canUseMirror . mirrorContent)
                  . mirrorsMirrors
                  . uninterpretedSigned

    -- Once we add support for partial mirrors, we wil need an additional
    -- argument to 'repWithMirror' (here, not in the Repository API itself)
    -- that tells us which files we will be requested from the mirror.
    -- We can then compare that against the specification of the partial mirror
    -- to see if all of those files are available from this mirror.
    canUseMirror :: MirrorContent -> Bool
    canUseMirror MirrorFull = True

{-------------------------------------------------------------------------------
  Exceptions
-------------------------------------------------------------------------------}

-- | Re-throw all exceptions thrown by the client API as unchecked exceptions
uncheckClientErrors :: ( ( Throws VerificationError
                         , Throws SomeRemoteError
                         , Throws InvalidPackageException
                         ) => IO a )
                     -> IO a
uncheckClientErrors act = handleChecked rethrowVerificationError
                        $ handleChecked rethrowSomeRemoteError
                        $ handleChecked rethrowInvalidPackageException
                        $ act
  where
     rethrowVerificationError :: VerificationError -> IO a
     rethrowVerificationError = throwIO

     rethrowSomeRemoteError :: SomeRemoteError -> IO a
     rethrowSomeRemoteError = throwIO

     rethrowInvalidPackageException :: InvalidPackageException -> IO a
     rethrowInvalidPackageException = throwIO

data InvalidPackageException = InvalidPackageException PackageIdentifier
  deriving (Typeable)

data LocalFileCorrupted = LocalFileCorrupted DeserializationError
  deriving (Typeable)

data InvalidFileInIndex = InvalidFileInIndex IndexFile DeserializationError
  deriving (Typeable)

#if MIN_VERSION_base(4,8,0)
deriving instance Show InvalidPackageException
deriving instance Show LocalFileCorrupted
deriving instance Show InvalidFileInIndex
instance Exception InvalidPackageException where displayException = pretty
instance Exception LocalFileCorrupted where displayException = pretty
instance Exception InvalidFileInIndex where displayException = pretty
#else
instance Show InvalidPackageException where show = pretty
instance Show LocalFileCorrupted where show = pretty
instance Show InvalidFileInIndex where show = pretty
instance Exception InvalidPackageException
instance Exception LocalFileCorrupted
instance Exception InvalidFileInIndex
#endif

instance Pretty InvalidPackageException where
  pretty (InvalidPackageException pkgId) = "Invalid package " ++ display pkgId

instance Pretty LocalFileCorrupted where
  pretty (LocalFileCorrupted err) = "Local file corrupted: " ++ pretty err

instance Pretty InvalidFileInIndex where
  pretty (InvalidFileInIndex file err) = "Invalid file " ++ pretty file
                                      ++ "in index: " ++ pretty err

{-------------------------------------------------------------------------------
  Auxiliary
-------------------------------------------------------------------------------}

-- | Local files are assumed trusted
--
-- There is no point tracking chain of trust for local files because that chain
-- would necessarily have to start at an implicitly trusted (though unverified)
-- file: the root metadata.
trustLocalFile :: Signed a -> Trusted a
trustLocalFile Signed{..} = DeclareTrusted signed

-- | Just a simple wrapper around 'verifyFileInfo'
--
-- Throws a VerificationError if verification failed.
verifyFileInfo' :: (MonadIO m, DownloadedFile down)
                => Maybe (Trusted FileInfo)
                -> TargetPath  -- ^ For error messages
                -> down typ    -- ^ File to verify
                -> m ()
verifyFileInfo' Nothing     _          _        = return ()
verifyFileInfo' (Just info) targetPath tempPath = liftIO $ do
    verified <- downloadedVerify tempPath info
    unless verified $ throw $ VerificationErrorFileInfo targetPath

readCachedJSON :: (MonadIO m, FromJSON ReadJSON_Keys_Layout a)
               => Repository down -> KeyEnv -> AbsolutePath
               -> m (Either DeserializationError a)
readCachedJSON Repository{..} keyEnv fp = liftIO $ do
    bs <- readLazyByteString fp
    evaluate $ parseJSON_Keys_Layout keyEnv repLayout bs

readDownloadedJSON :: (MonadIO m, FromJSON ReadJSON_Keys_Layout a)
                   => Repository down -> KeyEnv -> down Metadata
                   -> m (Either DeserializationError a)
readDownloadedJSON Repository{..} keyEnv fp = liftIO $ do
    bs <- downloadedRead fp
    evaluate $ parseJSON_Keys_Layout keyEnv repLayout bs

throwErrorsUnchecked :: ( MonadIO m
                        , Exception e'
                        )
                     => (e -> e') -> Either e a -> m a
throwErrorsUnchecked f (Left err) = liftIO $ throwUnchecked (f err)
throwErrorsUnchecked _ (Right a)  = return a

throwErrorsChecked :: ( Throws e'
                      , MonadIO m
                      , Exception e'
                      )
                   => (e -> e') -> Either e a -> m a
throwErrorsChecked f (Left err) = liftIO $ throwChecked (f err)
throwErrorsChecked _ (Right a)  = return a

eitherToMaybe :: Either a b -> Maybe b
eitherToMaybe (Left  _) = Nothing
eitherToMaybe (Right b) = Just b
