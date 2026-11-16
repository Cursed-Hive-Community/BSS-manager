# Win32 calls that PowerShell has no cmdlet for:
# - Remote Desktop sessions (enumerate, log off)
#   https://learn.microsoft.com/windows/win32/api/wtsapi32/
# - Credential Manager, so mstsc finds the password of each macro account
#   https://learn.microsoft.com/windows/win32/api/wincred/nf-wincred-credwritew
# - LSA private data, where Winlogon reads the auto-logon password
#   https://learn.microsoft.com/windows/win32/secauthn/protecting-the-automatic-logon-password
#
# Secrets only ever travel as SecureString and are copied to unmanaged memory
# that is zeroed straight after use, never as a managed string.

# A process compiles this once: a window opened before an update keeps the
# old type until it is closed and reopened.
if (-not ('BssNative' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Security;

public class BssSession {
  public int Id;
  public string Station;
  public string User;
  public int State;
}

public static class BssNative {
  // ---------------------------------------------------------------- sessions
  [StructLayout(LayoutKind.Sequential)]
  struct WTS_SESSION_INFO { public int SessionId; public IntPtr pWinStationName; public int State; }

  [DllImport("wtsapi32.dll", SetLastError = true)]
  static extern bool WTSEnumerateSessionsW(IntPtr server, int reserved, int version, out IntPtr info, out int count);
  [DllImport("wtsapi32.dll", SetLastError = true)]
  static extern bool WTSQuerySessionInformationW(IntPtr server, int sessionId, int infoClass, out IntPtr buffer, out int bytes);
  [DllImport("wtsapi32.dll")]
  static extern void WTSFreeMemory(IntPtr memory);
  [DllImport("wtsapi32.dll", SetLastError = true)]
  static extern bool WTSLogoffSession(IntPtr server, int sessionId, bool wait);

  const int WTSUserName = 5;

  public static List<BssSession> GetSessions() {
    List<BssSession> list = new List<BssSession>();
    IntPtr info; int count;
    if (!WTSEnumerateSessionsW(IntPtr.Zero, 0, 1, out info, out count)) return list;
    try {
      int size = Marshal.SizeOf(typeof(WTS_SESSION_INFO));
      for (int i = 0; i < count; i++) {
        WTS_SESSION_INFO s = (WTS_SESSION_INFO)Marshal.PtrToStructure(new IntPtr(info.ToInt64() + (long)i * size), typeof(WTS_SESSION_INFO));
        BssSession item = new BssSession();
        item.Id = s.SessionId;
        item.Station = Marshal.PtrToStringUni(s.pWinStationName);
        item.State = s.State;
        IntPtr buffer; int bytes;
        if (WTSQuerySessionInformationW(IntPtr.Zero, s.SessionId, WTSUserName, out buffer, out bytes)) {
          item.User = Marshal.PtrToStringUni(buffer);
          WTSFreeMemory(buffer);
        }
        list.Add(item);
      }
    } finally { WTSFreeMemory(info); }
    return list;
  }

  public static bool Logoff(int sessionId) { return WTSLogoffSession(IntPtr.Zero, sessionId, false); }

  // ------------------------------------------------------ credential manager
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  struct CREDENTIAL {
    public int Flags; public int Type; public string TargetName; public string Comment;
    public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
    public int CredentialBlobSize; public IntPtr CredentialBlob;
    public int Persist; public int AttributeCount; public IntPtr Attributes;
    public string TargetAlias; public string UserName;
  }

  [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
  static extern bool CredWrite(ref CREDENTIAL credential, int flags);
  [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
  static extern bool CredRead(string target, int type, int flags, out IntPtr credential);
  [DllImport("advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
  static extern bool CredDelete(string target, int type, int flags);
  [DllImport("advapi32.dll")]
  static extern void CredFree(IntPtr buffer);

  const int CRED_TYPE_GENERIC = 1;
  const int CRED_TYPE_DOMAIN_PASSWORD = 2;
  const int CRED_PERSIST_LOCAL_MACHINE = 2;

  public static void WriteCred(string target, string user, SecureString password) {
    IntPtr secret = Marshal.SecureStringToGlobalAllocUnicode(password);
    try {
      CREDENTIAL c = new CREDENTIAL();
      c.Type = CRED_TYPE_GENERIC;
      c.TargetName = target;
      c.UserName = user;
      c.Persist = CRED_PERSIST_LOCAL_MACHINE;
      c.CredentialBlobSize = password.Length * 2;
      c.CredentialBlob = secret;
      if (!CredWrite(ref c, 0)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    } finally { Marshal.ZeroFreeGlobalAllocUnicode(secret); }
  }

  // Reads a generic credential's secret straight into a SecureString,
  // character by character, never as a managed string. Null when absent.
  public static SecureString ReadCredSecure(string target) {
    IntPtr p;
    if (!CredRead(target, CRED_TYPE_GENERIC, 0, out p)) return null;
    try {
      CREDENTIAL c = (CREDENTIAL)Marshal.PtrToStructure(p, typeof(CREDENTIAL));
      SecureString s = new SecureString();
      for (int i = 0; i < c.CredentialBlobSize / 2; i++) s.AppendChar((char)Marshal.ReadInt16(c.CredentialBlob, i * 2));
      s.MakeReadOnly();
      return s;
    } finally { CredFree(p); }
  }

  // mstsc's own "remember me" box stores a domain credential, ours a generic
  // one: either lets the connection open without a prompt.
  public static bool CredExists(string target) {
    IntPtr p;
    foreach (int type in new int[] { CRED_TYPE_GENERIC, CRED_TYPE_DOMAIN_PASSWORD }) {
      if (CredRead(target, type, 0, out p)) { CredFree(p); return true; }
    }
    return false;
  }

  public static void DeleteCred(string target) {
    CredDelete(target, CRED_TYPE_GENERIC, 0);
    CredDelete(target, CRED_TYPE_DOMAIN_PASSWORD, 0);
  }

  // --------------------------------------------------------- LSA secrets
  [StructLayout(LayoutKind.Sequential)]
  struct LSA_UNICODE_STRING { public ushort Length; public ushort MaximumLength; public IntPtr Buffer; }
  [StructLayout(LayoutKind.Sequential)]
  struct LSA_OBJECT_ATTRIBUTES {
    public int Length; public IntPtr RootDirectory; public IntPtr ObjectName; public int Attributes;
    public IntPtr SecurityDescriptor; public IntPtr SecurityQualityOfService;
  }

  [DllImport("advapi32.dll")]
  static extern uint LsaOpenPolicy(IntPtr systemName, ref LSA_OBJECT_ATTRIBUTES attributes, int access, out IntPtr policy);
  [DllImport("advapi32.dll")]
  static extern uint LsaStorePrivateData(IntPtr policy, ref LSA_UNICODE_STRING key, IntPtr data);
  [DllImport("advapi32.dll")]
  static extern uint LsaRetrievePrivateData(IntPtr policy, ref LSA_UNICODE_STRING key, out IntPtr data);
  [DllImport("advapi32.dll")]
  static extern uint LsaFreeMemory(IntPtr buffer);
  [DllImport("advapi32.dll")]
  static extern uint LsaClose(IntPtr policy);
  [DllImport("advapi32.dll")]
  static extern int LsaNtStatusToWinError(uint status);

  const int POLICY_CREATE_SECRET = 0x20;
  const int POLICY_GET_PRIVATE_INFORMATION = 0x04;
  const uint STATUS_OBJECT_NAME_NOT_FOUND = 0xC0000034;

  static IntPtr OpenPolicy(int access) {
    LSA_OBJECT_ATTRIBUTES attributes = new LSA_OBJECT_ATTRIBUTES();
    attributes.Length = Marshal.SizeOf(typeof(LSA_OBJECT_ATTRIBUTES));
    IntPtr policy;
    uint status = LsaOpenPolicy(IntPtr.Zero, ref attributes, access, out policy);
    if (status != 0) throw new System.ComponentModel.Win32Exception(LsaNtStatusToWinError(status));
    return policy;
  }

  static LSA_UNICODE_STRING KeyOf(string name, IntPtr buffer) {
    LSA_UNICODE_STRING key = new LSA_UNICODE_STRING();
    key.Buffer = buffer;
    key.Length = (ushort)(name.Length * 2);
    key.MaximumLength = (ushort)(name.Length * 2 + 2);
    return key;
  }

  // value == null deletes the secret.
  public static void StoreLsaSecret(string name, SecureString value) {
    IntPtr policy = OpenPolicy(POLICY_CREATE_SECRET);
    IntPtr keyBuffer = Marshal.StringToHGlobalUni(name);
    IntPtr secret = IntPtr.Zero;
    IntPtr data = IntPtr.Zero;
    try {
      LSA_UNICODE_STRING key = KeyOf(name, keyBuffer);
      if (value != null) {
        secret = Marshal.SecureStringToGlobalAllocUnicode(value);
        LSA_UNICODE_STRING s = new LSA_UNICODE_STRING();
        s.Buffer = secret;
        s.Length = (ushort)(value.Length * 2);
        s.MaximumLength = (ushort)(value.Length * 2 + 2);
        data = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(LSA_UNICODE_STRING)));
        Marshal.StructureToPtr(s, data, false);
      }
      uint status = LsaStorePrivateData(policy, ref key, data);
      if (status != 0 && !(value == null && status == STATUS_OBJECT_NAME_NOT_FOUND)) {
        throw new System.ComponentModel.Win32Exception(LsaNtStatusToWinError(status));
      }
    } finally {
      if (data != IntPtr.Zero) Marshal.FreeHGlobal(data);
      if (secret != IntPtr.Zero) Marshal.ZeroFreeGlobalAllocUnicode(secret);
      Marshal.FreeHGlobal(keyBuffer);
      LsaClose(policy);
    }
  }

  // Says whether a secret exists without ever handing its value back.
  public static bool LsaSecretExists(string name) {
    IntPtr policy = OpenPolicy(POLICY_GET_PRIVATE_INFORMATION);
    IntPtr keyBuffer = Marshal.StringToHGlobalUni(name);
    try {
      LSA_UNICODE_STRING key = KeyOf(name, keyBuffer);
      IntPtr data;
      uint status = LsaRetrievePrivateData(policy, ref key, out data);
      if (status != 0) return false;
      if (data != IntPtr.Zero) {
        LSA_UNICODE_STRING s = (LSA_UNICODE_STRING)Marshal.PtrToStructure(data, typeof(LSA_UNICODE_STRING));
        byte[] zero = new byte[s.Length];
        if (s.Buffer != IntPtr.Zero && s.Length > 0) Marshal.Copy(zero, 0, s.Buffer, s.Length);
        LsaFreeMemory(data);
      }
      return true;
    } finally {
      Marshal.FreeHGlobal(keyBuffer);
      LsaClose(policy);
    }
  }
}
'@
}
