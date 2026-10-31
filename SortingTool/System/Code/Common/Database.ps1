# Database.ps1
# SQLite database System/Database/index.db (base section 10).
#
# Access goes through the SQLite engine that is part of Windows 10 and 11 (winsqlite3.dll in
# System32). A small C# wrapper is compiled at start with Add-Type, so nothing has to be
# installed and no extra DLL is needed (see doc/BuildAssumptions.md, A-03).
#
# Rows are returned as dictionaries; PowerShell allows $row.Path as well as $row['Path'].

$global:ST.FileColumns = @('Path', 'Hash', 'SimilarityHash', 'Size', 'Modified', 'LastChecked', 'DuplicateChecked',
    'CaptureDate', 'CaptureDateSource', 'Latitude', 'Longitude', 'Category', 'Keyword', 'NameHint', 'CategorySetHash')

$sqliteSource = @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace SortingTool
{
    public sealed class SqliteDb : IDisposable
    {
        private const string Dll = "winsqlite3.dll";
        private static readonly IntPtr Transient = new IntPtr(-1);

        [DllImport(Dll, CallingConvention = CallingConvention.StdCall)]
        private static extern int sqlite3_open_v2(byte[] filename, out IntPtr db, int flags, IntPtr vfs);
        [DllImport(Dll, CallingConvention = CallingConvention.StdCall)]
        private static extern int sqlite3_close(IntPtr db);
        [DllImport(Dll, CallingConvention = CallingConvention.StdCall)]
        private static extern int sqlite3_busy_timeout(IntPtr db, int ms);
        [DllImport(Dll, CallingConvention = CallingConvention.StdCall, CharSet = CharSet.Unicode)]
        private static extern int sqlite3_prepare16_v2(IntPtr db, string sql, int nBytes, out IntPtr stmt, out IntPtr tail);
        [DllImport(Dll, CallingConvention = CallingConvention.StdCall)]
        private static extern int sqlite3_step(IntPtr stmt);
        [DllImport(Dll, CallingConvention = CallingConvention.StdCall)]
        private static extern int sqlite3_finalize(IntPtr stmt);
        [DllImport(Dll, CallingConvention = CallingConvention.StdCall)]
        private static extern IntPtr sqlite3_errmsg16(IntPtr db);
        [DllImport(Dll, CallingConvention = CallingConvention.StdCall)]
        private static extern int sqlite3_changes(IntPtr db);
        [DllImport(Dll, CallingConvention = CallingConvention.StdCall)]
        private static extern int sqlite3_bind_parameter_index(IntPtr stmt, byte[] name);
        [DllImport(Dll, CallingConvention = CallingConvention.StdCall, CharSet = CharSet.Unicode)]
        private static extern int sqlite3_bind_text16(IntPtr stmt, int index, string value, int nBytes, IntPtr destructor);
        [DllImport(Dll, CallingConvention = CallingConvention.StdCall)]
        private static extern int sqlite3_bind_int64(IntPtr stmt, int index, long value);
        [DllImport(Dll, CallingConvention = CallingConvention.StdCall)]
        private static extern int sqlite3_bind_double(IntPtr stmt, int index, double value);
        [DllImport(Dll, CallingConvention = CallingConvention.StdCall)]
        private static extern int sqlite3_bind_null(IntPtr stmt, int index);
        [DllImport(Dll, CallingConvention = CallingConvention.StdCall)]
        private static extern int sqlite3_column_count(IntPtr stmt);
        [DllImport(Dll, CallingConvention = CallingConvention.StdCall)]
        private static extern IntPtr sqlite3_column_name16(IntPtr stmt, int index);
        [DllImport(Dll, CallingConvention = CallingConvention.StdCall)]
        private static extern int sqlite3_column_type(IntPtr stmt, int index);
        [DllImport(Dll, CallingConvention = CallingConvention.StdCall)]
        private static extern long sqlite3_column_int64(IntPtr stmt, int index);
        [DllImport(Dll, CallingConvention = CallingConvention.StdCall)]
        private static extern double sqlite3_column_double(IntPtr stmt, int index);
        [DllImport(Dll, CallingConvention = CallingConvention.StdCall)]
        private static extern IntPtr sqlite3_column_text16(IntPtr stmt, int index);

        private IntPtr db;

        public SqliteDb(string path)
        {
            // SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
            int rc = sqlite3_open_v2(Utf8z(path), out db, 0x02 | 0x04 | 0x10000, IntPtr.Zero);
            if (rc != 0)
            {
                string message = db != IntPtr.Zero ? LastError() : "code " + rc;
                throw new Exception("Cannot open database " + path + ": " + message);
            }
            sqlite3_busy_timeout(db, 5000);
        }

        private static byte[] Utf8z(string s)
        {
            byte[] b = Encoding.UTF8.GetBytes(s);
            byte[] r = new byte[b.Length + 1];
            Buffer.BlockCopy(b, 0, r, 0, b.Length);
            return r;
        }

        private string LastError()
        {
            return Marshal.PtrToStringUni(sqlite3_errmsg16(db));
        }

        private static object Unwrap(object v)
        {
            if (v == null) return null;
            Type t = v.GetType();
            if (t.FullName == "System.Management.Automation.PSObject")
            {
                object b = t.GetProperty("BaseObject").GetValue(v, null);
                return b;
            }
            return v;
        }

        private IntPtr Prepare(string sql, IDictionary parameters)
        {
            IntPtr stmt;
            IntPtr tail;
            int rc = sqlite3_prepare16_v2(db, sql, sql.Length * 2, out stmt, out tail);
            if (rc != 0) throw new Exception("SQL error: " + LastError() + " | " + sql);
            if (parameters == null) return stmt;
            foreach (DictionaryEntry e in parameters)
            {
                string name = e.Key.ToString();
                if (!name.StartsWith("@")) name = "@" + name;
                int idx = sqlite3_bind_parameter_index(stmt, Utf8z(name));
                if (idx == 0) continue;
                object v = Unwrap(e.Value);
                if (v == null || v is DBNull) sqlite3_bind_null(stmt, idx);
                else if (v is bool) sqlite3_bind_int64(stmt, idx, ((bool)v) ? 1 : 0);
                else if (v is int || v is long || v is short || v is byte || v is uint || v is ushort) sqlite3_bind_int64(stmt, idx, Convert.ToInt64(v));
                else if (v is ulong) sqlite3_bind_int64(stmt, idx, unchecked((long)(ulong)v));
                else if (v is double || v is float || v is decimal) sqlite3_bind_double(stmt, idx, Convert.ToDouble(v));
                else if (v is DateTime) sqlite3_bind_text16(stmt, idx, ((DateTime)v).ToString("yyyy-MM-ddTHH:mm:ss"), -1, Transient);
                else sqlite3_bind_text16(stmt, idx, v.ToString(), -1, Transient);
            }
            return stmt;
        }

        public int Execute(string sql, IDictionary parameters)
        {
            IntPtr stmt = Prepare(sql, parameters);
            try
            {
                int rc = sqlite3_step(stmt);
                if (rc != 100 && rc != 101) throw new Exception("SQL error: " + LastError() + " | " + sql);
                return sqlite3_changes(db);
            }
            finally { sqlite3_finalize(stmt); }
        }

        public List<Dictionary<string, object>> Query(string sql, IDictionary parameters)
        {
            List<Dictionary<string, object>> rows = new List<Dictionary<string, object>>();
            IntPtr stmt = Prepare(sql, parameters);
            try
            {
                int count = sqlite3_column_count(stmt);
                string[] names = new string[count];
                for (int i = 0; i < count; i++) names[i] = Marshal.PtrToStringUni(sqlite3_column_name16(stmt, i));
                while (true)
                {
                    int rc = sqlite3_step(stmt);
                    if (rc == 101) break;
                    if (rc != 100) throw new Exception("SQL error: " + LastError() + " | " + sql);
                    Dictionary<string, object> row = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
                    for (int i = 0; i < count; i++)
                    {
                        int type = sqlite3_column_type(stmt, i);
                        object value;
                        if (type == 1) value = sqlite3_column_int64(stmt, i);
                        else if (type == 2) value = sqlite3_column_double(stmt, i);
                        else if (type == 5) value = null;
                        else value = Marshal.PtrToStringUni(sqlite3_column_text16(stmt, i));
                        row[names[i]] = value;
                    }
                    rows.Add(row);
                }
            }
            finally { sqlite3_finalize(stmt); }
            return rows;
        }

        public void Dispose()
        {
            if (db != IntPtr.Zero) { sqlite3_close(db); db = IntPtr.Zero; }
        }
    }
}
'@

function Open-ToolDatabase {
    if ($global:ST.Db) { return }
    if (-not ('SortingTool.SqliteDb' -as [type])) {
        Add-Type -TypeDefinition $sqliteSource -Language CSharp
    }
    try {
        $global:ST.Db = New-Object SortingTool.SqliteDb $global:ST.DbPath
    }
    catch {
        throw "Die Datenbank konnte nicht geöffnet werden (winsqlite3.dll fehlt? Windows 10 oder neuer nötig): $($_.Exception.Message)"
    }
    Initialize-DatabaseSchema
}

function Close-ToolDatabase {
    if ($global:ST.Db) { $global:ST.Db.Dispose(); $global:ST.Db = $null }
}

function Invoke-DbQuery {
    param([Parameter(Mandatory)][string]$Sql, [hashtable]$Params = @{})
    return , ($global:ST.Db.Query($Sql, $Params))
}

function Invoke-DbExecute {
    param([Parameter(Mandatory)][string]$Sql, [hashtable]$Params = @{})
    return $global:ST.Db.Execute($Sql, $Params)
}

function Invoke-DbScalar {
    param([Parameter(Mandatory)][string]$Sql, [hashtable]$Params = @{})
    $rows = $global:ST.Db.Query($Sql, $Params)
    if ($rows.Count -eq 0) { return $null }
    foreach ($v in $rows[0].Values) { return $v }
}

function Start-DbTransaction { [void](Invoke-DbExecute 'BEGIN') }
function Complete-DbTransaction { [void](Invoke-DbExecute 'COMMIT') }
function Undo-DbTransaction { try { [void](Invoke-DbExecute 'ROLLBACK') } catch { } }

function Initialize-DatabaseSchema {
    [void](Invoke-DbExecute @'
CREATE TABLE IF NOT EXISTS Files (
    Path TEXT NOT NULL PRIMARY KEY COLLATE NOCASE,
    Hash TEXT,
    SimilarityHash TEXT,
    Size INTEGER,
    Modified TEXT,
    LastChecked TEXT,
    DuplicateChecked TEXT,
    CaptureDate TEXT,
    CaptureDateSource TEXT,
    Latitude REAL,
    Longitude REAL,
    Category TEXT,
    Keyword TEXT,
    NameHint TEXT,
    CategorySetHash TEXT
)
'@)
    # Columns added by later specifications are added to older databases.
    $existing = New-PathSet
    foreach ($row in (Invoke-DbQuery 'PRAGMA table_info(Files)')) { [void]$existing.Add([string]$row.name) }
    $types = @{ Latitude = 'REAL'; Longitude = 'REAL'; Size = 'INTEGER' }
    foreach ($col in $global:ST.FileColumns) {
        if (-not $existing.Contains($col)) {
            $type = 'TEXT'
            if ($types.ContainsKey($col)) { $type = $types[$col] }
            [void](Invoke-DbExecute "ALTER TABLE Files ADD COLUMN $col $type")
        }
    }
    [void](Invoke-DbExecute 'CREATE INDEX IF NOT EXISTS IX_Files_Hash ON Files(Hash)')
    [void](Invoke-DbExecute @'
CREATE TABLE IF NOT EXISTS GeoCache (
    Latitude REAL NOT NULL,
    Longitude REAL NOT NULL,
    Zoom INTEGER NOT NULL,
    Language TEXT NOT NULL,
    Response TEXT,
    Place TEXT,
    RetrievedAt TEXT,
    PRIMARY KEY (Latitude, Longitude, Zoom, Language)
)
'@)
}

function Test-Key {
    # Works for hashtables, ordered dictionaries and the dictionary rows of the database.
    param($Dictionary, [string]$Key)
    if ($null -eq $Dictionary) { return $false }
    if ($Dictionary -is [System.Collections.Specialized.OrderedDictionary]) { return $Dictionary.Contains($Key) }
    return $Dictionary.ContainsKey($Key)
}

function Get-NowText { return (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss') }

function Get-FileEntry {
    param([Parameter(Mandatory)][string]$RelPath)
    $rows = Invoke-DbQuery 'SELECT * FROM Files WHERE Path = @p' @{ p = $RelPath }
    if ($rows.Count -eq 0) { return $null }
    return $rows[0]
}

function Set-FileEntry {
    # Inserts or replaces a full row. $Entry: hashtable or dictionary with the column names.
    param([Parameter(Mandatory)]$Entry)
    $params = @{}
    foreach ($col in $global:ST.FileColumns) {
        $value = $null
        if (Test-Key $Entry $col) { $value = $Entry[$col] }
        $params[$col] = $value
    }
    $cols = $global:ST.FileColumns -join ', '
    $vals = ($global:ST.FileColumns | ForEach-Object { "@$_" }) -join ', '
    [void](Invoke-DbExecute "INSERT OR REPLACE INTO Files ($cols) VALUES ($vals)" $params)
}

function Update-FileEntryFields {
    # Sets some columns of one row, e.g. @{ DuplicateChecked = '...' }.
    param([Parameter(Mandatory)][string]$RelPath, [Parameter(Mandatory)][hashtable]$Fields)
    $sets = @()
    $params = @{ p = $RelPath }
    $i = 0
    foreach ($k in $Fields.Keys) {
        if ($global:ST.FileColumns -notcontains $k) { throw "Unknown column $k" }
        $sets += "$k = @v$i"
        $params["v$i"] = $Fields[$k]
        $i++
    }
    if ($sets.Count -eq 0) { return }
    [void](Invoke-DbExecute ("UPDATE Files SET " + ($sets -join ', ') + " WHERE Path = @p") $params)
}

function Remove-FileEntry {
    param([Parameter(Mandatory)][string]$RelPath)
    [void](Invoke-DbExecute 'DELETE FROM Files WHERE Path = @p' @{ p = $RelPath })
}

function Update-EntryPath {
    # A file was moved or renamed: only the path changes, the hashes stay (base section 10).
    param([Parameter(Mandatory)][string]$OldPath, [Parameter(Mandatory)][string]$NewPath)
    if (Test-RelEqual $OldPath $NewPath) {
        # Only the case changed.
        [void](Invoke-DbExecute 'UPDATE Files SET Path = @n WHERE Path = @o' @{ o = $OldPath; n = $NewPath })
        return
    }
    # A stale row at the new path would block the update; it describes a file that no longer exists there.
    [void](Invoke-DbExecute 'DELETE FROM Files WHERE Path = @n' @{ n = $NewPath })
    [void](Invoke-DbExecute 'UPDATE Files SET Path = @n WHERE Path = @o' @{ o = $OldPath; n = $NewPath })
}

function Update-EntryFolderPath {
    # A folder was moved or renamed: every entry below it gets the new prefix (base section 11).
    param([Parameter(Mandatory)][string]$OldFolder, [Parameter(Mandatory)][string]$NewFolder)
    $old = $OldFolder.TrimEnd('/') + '/'
    $new = $NewFolder.TrimEnd('/') + '/'
    $rows = Invoke-DbQuery 'SELECT Path FROM Files WHERE lower(substr(Path, 1, @len)) = lower(@old)' @{ len = $old.Length; old = $old }
    foreach ($row in $rows) {
        $newPath = $new + ([string]$row.Path).Substring($old.Length)
        Update-EntryPath -OldPath $row.Path -NewPath $newPath
    }
}

function Get-EntriesUnder {
    # All rows whose path lies below the given folder ("Input", "Result/Images", ...).
    param([Parameter(Mandatory)][string]$Folder)
    $prefix = $Folder.TrimEnd('/') + '/'
    return , (Invoke-DbQuery 'SELECT * FROM Files WHERE lower(substr(Path, 1, @len)) = lower(@pre)' @{ len = $prefix.Length; pre = $prefix })
}

function Get-EntriesByHash {
    param([Parameter(Mandatory)][string]$Hash)
    return , (Invoke-DbQuery 'SELECT * FROM Files WHERE Hash = @h' @{ h = $Hash })
}

function ConvertTo-EntryHashtable {
    # Dictionary row -> plain hashtable (for JSON in logs).
    param([Parameter(Mandatory)]$Row)
    $h = [ordered]@{}
    foreach ($col in $global:ST.FileColumns) {
        if (Test-Key $Row $col) { $h[$col] = $Row[$col] } else { $h[$col] = $null }
    }
    return $h
}
