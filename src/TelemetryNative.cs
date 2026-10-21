using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
using System.Security.Cryptography;
using System.Threading.Tasks;
namespace AIBattery {
 public sealed class RolloutLine { public string Text; public long EndOffset; }
 public sealed class BoundedRolloutChunk { public long Offset; public RolloutLine[] Lines; public string Fragment; public bool Skipping; public int BytesRead; public int DroppedLines; }
 public sealed class RolloutChunk { public long Offset; public string[] Lines; public bool Skipping; }
 public static class RolloutReader {
  // Console.In is synchronized and its ReadLineAsync may block on .NET Framework.
  public static string ReadProtocolFrame() {
   var line=new StringBuilder();int c;
   while((c=Console.In.Read())!=-1){if(c==10)return line.ToString().TrimEnd('\r');if(line.Length>=262144)throw new InvalidDataException("FRAME_LIMIT");line.Append((char)c);}
   return line.Length==0?null:line.ToString();
  }
  public static Task<string> ReadProtocolLine() { return Task.Factory.StartNew(() => ReadProtocolFrame()); }
  public static string Key(string[] parts) {
   var b=new StringBuilder("[");
   for(int p=0;p<parts.Length;p++) {
    if(p>0)b.Append(','); if(parts[p]==null){b.Append("null");continue;} b.Append('"');
    foreach(char c in parts[p]) {
     switch(c) {case '"':b.Append("\\\"");break;case '\\':b.Append("\\\\");break;case '\b':b.Append("\\b");break;case '\f':b.Append("\\f");break;case '\n':b.Append("\\n");break;case '\r':b.Append("\\r");break;case '\t':b.Append("\\t");break;default:if(c<32)b.Append("\\u"+((int)c).ToString("x4"));else b.Append(c);break;}
    }
    b.Append('"');
   }
   b.Append(']');using(var sha=SHA256.Create())return BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(b.ToString()))).Replace("-","").ToLowerInvariant();
  }
  // The byte cursor and bounded UTF-8 fragment are checkpointed together. Decode only complete lines.
  public static BoundedRolloutChunk ReadBounded(string path,long offset,int maxBytes,string fragment,bool skipping) {
   using(var f=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete)) {
    if(offset>f.Length){offset=0;fragment=null;skipping=false;}f.Position=offset;
    var old=String.IsNullOrEmpty(fragment)?new byte[0]:Convert.FromBase64String(fragment);
    int size=(int)Math.Min(Math.Max(0,maxBytes),f.Length-offset);var buffer=new byte[size];int count=0,n;
    while(count<size&&(n=f.Read(buffer,count,size-count))>0)count+=n;
    var lines=new List<RolloutLine>();var pending=new MemoryStream();if(!skipping)pending.Write(old,0,old.Length);int dropped=0;
    for(int i=0;i<count;i++) {
     if(buffer[i]==10) {
      if(!skipping){var bytes=pending.ToArray();int length=bytes.Length;if(length>0&&bytes[length-1]==13)length--;try{lines.Add(new RolloutLine{Text=new UTF8Encoding(false,true).GetString(bytes,0,length),EndOffset=offset+i+1});}catch(DecoderFallbackException){dropped++;}}
      else dropped++;
      pending.SetLength(0);skipping=false;
     } else if(!skipping) {
      pending.WriteByte(buffer[i]);if(pending.Length>4*1024*1024){pending.SetLength(0);skipping=true;}
     }
    }
    return new BoundedRolloutChunk{Offset=offset+count,Lines=lines.ToArray(),Fragment=pending.Length==0?null:Convert.ToBase64String(pending.ToArray()),Skipping=skipping,BytesRead=count,DroppedLines=dropped};
   }
  }
  public static RolloutChunk Read(string path, long offset, bool skipping) {
   using (var f = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) {
    if (offset > f.Length) {offset = 0;skipping=false;}
    f.Position = offset;
    byte[] bytes = new byte[(int)Math.Min(4 * 1024 * 1024, f.Length-offset)];
    int count=0, read;
    while (count<bytes.Length && (read=f.Read(bytes,count,bytes.Length-count))>0) count+=read;
    int start=0;
    if(skipping) {
     while(start<count && bytes[start]!=10) start++;
     if(start==count) return new RolloutChunk {Offset=offset+count,Lines=new string[0],Skipping=true};
     start++;skipping=false;
    }
    int end=count-1; while(end>=start && bytes[end]!=10) end--;
    if(end<start) {
     bool oversized=count==4*1024*1024;
     return new RolloutChunk { Offset=oversized ? offset+count : offset+start, Lines=new string[0],Skipping=oversized };
    }
    return new RolloutChunk { Offset=offset+end+1, Lines=Encoding.UTF8.GetString(bytes,start,end+1-start).Split(new char[]{'\n'},StringSplitOptions.RemoveEmptyEntries),Skipping=false };
   }
  }
 }
}
