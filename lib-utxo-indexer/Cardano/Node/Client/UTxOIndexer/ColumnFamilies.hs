{- |
Module      : Cardano.Node.Client.UTxOIndexer.ColumnFamilies
Description : Create column families on an open RocksDB handle
License     : Apache-2.0

The pinned RocksDB binding opens a store with a fixed column-family
list but exposes no way to add a family to an existing store. Its
'DB' record carries the raw handle, and the library it links exports
@rocksdb_create_column_family@; this module binds that call so a store
written before the asset index can gain the families it lacks.
-}
module Cardano.Node.Client.UTxOIndexer.ColumnFamilies (
    createColumnFamilies,
) where

import Control.Exception (bracket)
import Control.Monad (unless, when)
import Data.Default.Class (def)
import Database.RocksDB (Config, DB (..))
import Foreign.C.String (CString, peekCString, withCString)
import Foreign.Marshal.Alloc (alloca, free)
import Foreign.Ptr (Ptr, castPtr, nullPtr)
import Foreign.Storable (peek, poke)

foreign import ccall safe "rocksdb_options_create"
    c_options_create :: IO (Ptr ())

foreign import ccall safe "rocksdb_options_destroy"
    c_options_destroy :: Ptr () -> IO ()

foreign import ccall safe "rocksdb_create_column_family"
    c_create_column_family ::
        Ptr () -> Ptr () -> CString -> Ptr CString -> IO (Ptr ())

foreign import ccall safe "rocksdb_column_family_handle_destroy"
    c_column_family_handle_destroy :: Ptr () -> IO ()

{- | Create each named column family on an open store, in list order,
and release the handles RocksDB returns: the families are used by
reopening the store with them listed. Families are created with
RocksDB's default options, which is what the default 'Config' asks
for; any other 'Config' is refused. A RocksDB error raises an
'IOException' naming the family.
-}
createColumnFamilies :: DB -> [(String, Config)] -> IO ()
createColumnFamilies db = mapM_ create
  where
    create (name, config) = do
        unless (config == def) $
            ioError . userError $
                "create_column_family "
                    <> name
                    <> ": only default options are supported"
        bracket c_options_create c_options_destroy $ \opts ->
            withCString name $ \cName ->
                alloca $ \errPtr -> do
                    poke errPtr nullPtr
                    handle <-
                        c_create_column_family
                            (castPtr (rocksDB db))
                            opts
                            cName
                            errPtr
                    err <- peek errPtr
                    when (err /= nullPtr) $ do
                        message <- peekCString err
                        free err
                        ioError . userError $
                            "create_column_family "
                                <> name
                                <> ": "
                                <> message
                    c_column_family_handle_destroy handle
