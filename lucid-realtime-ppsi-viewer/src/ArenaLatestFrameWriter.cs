using System;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.MemoryMappedFiles;
using System.Threading;

class ArenaLatestFrameWriter
{
    const string DefaultSharedMemoryName = "Local\\RealtimePPSI_Frame";
    const int SharedHeaderSize = 128;
    const int SharedMagic = 0x49535050; // "PPSI" on little-endian Windows

    sealed class SharedFramePublisher : IDisposable
    {
        readonly MemoryMappedFile map;
        readonly MemoryMappedViewAccessor view;
        readonly int frameCapacity;
        long sequence;
        int activeBuffer = 1;

        public SharedFramePublisher(string name, int capacity)
        {
            frameCapacity = capacity;
            long totalBytes = SharedHeaderSize + 2L * capacity;
            map = MemoryMappedFile.CreateOrOpen(name, totalBytes,
                MemoryMappedFileAccess.ReadWrite);
            view = map.CreateViewAccessor(0, totalBytes,
                MemoryMappedFileAccess.ReadWrite);
            view.Write(0, SharedMagic);
            view.Write(4, 1);
            view.Write(8, SharedHeaderSize);
            view.Write(12, frameCapacity);
            view.Write(32, 0L);
            view.Flush();
        }

        public void Publish(byte[] data, int width, int height, int bpp,
            ulong timestampNs, long frameCount, long dropped,
            double exposureUs, double gain, double cameraFps,
            double acquisitionFps)
        {
            if (data.Length > frameCapacity)
                throw new InvalidOperationException("Frame exceeds shared-memory capacity.");

            int nextBuffer = 1 - activeBuffer;
            long oddSequence = sequence + 1;
            view.Write(32, oddSequence);
            Thread.MemoryBarrier();

            long dataOffset = SharedHeaderSize + (long)nextBuffer * frameCapacity;
            view.WriteArray(dataOffset, data, 0, data.Length);
            view.Write(16, width);
            view.Write(20, height);
            view.Write(24, bpp);
            view.Write(28, nextBuffer);
            view.Write(40, timestampNs);
            view.Write(48, frameCount);
            view.Write(56, dropped);
            view.Write(64, exposureUs);
            view.Write(72, gain);
            view.Write(80, cameraFps);
            view.Write(88, acquisitionFps);
            Thread.MemoryBarrier();

            sequence = oddSequence + 1;
            view.Write(32, sequence);
            activeBuffer = nextBuffer;
        }

        public void Dispose()
        {
            view.Dispose();
            map.Dispose();
        }
    }

    static string Arg(string[] args, string name, string def = "")
    {
        for (int i = 0; i < args.Length - 1; i++)
            if (args[i].Equals(name, StringComparison.OrdinalIgnoreCase))
                return args[i + 1];
        return def;
    }

    static bool HasArg(string[] args, string name)
    {
        foreach (string arg in args)
            if (arg.Equals(name, StringComparison.OrdinalIgnoreCase))
                return true;
        return false;
    }

    static double? DoubleArg(string[] args, string name)
    {
        string value = Arg(args, name);
        if (string.IsNullOrWhiteSpace(value))
            return null;
        return double.Parse(value, CultureInfo.InvariantCulture);
    }

    static long? LongArg(string[] args, string name)
    {
        string value = Arg(args, name);
        if (string.IsNullOrWhiteSpace(value))
            return null;
        return long.Parse(value, CultureInfo.InvariantCulture);
    }

    static void SetEnum(ArenaNET.INodeMap map, string name, string value)
    {
        if (string.IsNullOrWhiteSpace(value))
            return;
        var node = map.GetNode(name) as ArenaNET.IEnumeration;
        if (node != null && node.IsWritable)
            node.FromString(value);
    }

    static void SetBool(ArenaNET.INodeMap map, string name, bool value)
    {
        var node = map.GetNode(name) as ArenaNET.IBoolean;
        if (node != null && node.IsWritable)
            node.Value = value;
    }

    static double SetFloat(ArenaNET.INodeMap map, string name, double? value)
    {
        var node = map.GetNode(name) as ArenaNET.IFloat;
        if (node == null || !node.IsReadable)
            return double.NaN;
        if (value.HasValue && node.IsWritable)
            node.Value = Math.Max(node.Min, Math.Min(node.Max, value.Value));
        return node.Value;
    }

    static void ApplyControlFile(
        ArenaNET.INodeMap map,
        string controlFile,
        double maxExposureUs,
        ref DateTime lastControlWriteUtc,
        ref double actualExposureUs,
        ref double actualGain)
    {
        if (string.IsNullOrWhiteSpace(controlFile) || !File.Exists(controlFile))
            return;

        DateTime writeUtc = File.GetLastWriteTimeUtc(controlFile);
        if (writeUtc == lastControlWriteUtc)
            return;

        try
        {
            string[] lines = File.ReadAllLines(controlFile);
            foreach (string line in lines)
            {
                string[] parts = line.Split(new char[] { '=' }, 2);
                if (parts.Length != 2)
                    continue;

                double value;
                if (!double.TryParse(parts[1], NumberStyles.Float,
                    CultureInfo.InvariantCulture, out value))
                    continue;

                if (parts[0].Equals("exposureUs", StringComparison.OrdinalIgnoreCase))
                    actualExposureUs = SetFloat(map, "ExposureTime",
                        Math.Min(value, maxExposureUs));
                else if (parts[0].Equals("gain", StringComparison.OrdinalIgnoreCase))
                    actualGain = SetFloat(map, "Gain", value);
            }
            lastControlWriteUtc = writeUtc;
        }
        catch (IOException)
        {
            // MATLAB may be replacing the control file. Retry on the next frame.
        }
    }

    static long SetInteger(ArenaNET.INodeMap map, string name, long? value)
    {
        var node = map.GetNode(name) as ArenaNET.IInteger;
        if (node == null || !node.IsReadable)
            return 0;
        if (value.HasValue && node.IsWritable)
        {
            long v = Math.Max(node.Min, Math.Min(node.Max, value.Value));
            if (node.Inc > 1)
                v = node.Min + ((v - node.Min) / node.Inc) * node.Inc;
            node.Value = v;
        }
        return node.Value;
    }

    static int BytesPerPixel(string pixelFormat)
    {
        if (pixelFormat.IndexOf("PolarizedAngles", StringComparison.OrdinalIgnoreCase) >= 0 ||
            pixelFormat.IndexOf("PolarizedStokes", StringComparison.OrdinalIgnoreCase) >= 0)
            return 4;
        if (pixelFormat.IndexOf("PolarizedDolpAolp", StringComparison.OrdinalIgnoreCase) >= 0)
            return 2;
        if (pixelFormat.IndexOf("Mono16", StringComparison.OrdinalIgnoreCase) >= 0)
            return 2;
        return 1;
    }

    static void AtomicWriteText(string path, string text)
    {
        using (var fs = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.Read))
        using (var writer = new StreamWriter(fs))
        {
            writer.Write(text);
        }
    }

    static bool TryAtomicWriteText(string path, string text)
    {
        try
        {
            AtomicWriteText(path, text);
            return true;
        }
        catch (IOException)
        {
            return false;
        }
        catch (UnauthorizedAccessException)
        {
            return false;
        }
    }

    static string Safe(Func<string> getter)
    {
        try { return getter(); } catch { return "?"; }
    }

    static void ListDevices(ArenaNET.ISystem system)
    {
        system.UpdateDevices(1000);
        Console.WriteLine("Devices: {0}", system.Devices.Count);
        for (int i = 0; i < system.Devices.Count; i++)
        {
            var d = system.Devices[i];
            Console.WriteLine("[{0}] {1} serial={2} ip={3}", i,
                Safe(() => d.ModelName), Safe(() => d.SerialNumber), Safe(() => d.IpAddressStr));
        }
    }

    static int Main(string[] args)
    {
        string outDir = Arg(args, "--outdir", ".");
        string pixel = Arg(args, "--pixel", "PolarizedAngles_0d_45d_90d_135d_Mono8");
        string stopFile = Arg(args, "--stopfile", "");
        string controlFile = Arg(args, "--controlfile", "");
        string sharedMemoryName = Arg(args, "--sharedmemory", DefaultSharedMemoryName);
        int deviceIndex = int.Parse(Arg(args, "--device", "0"), CultureInfo.InvariantCulture);
        int durationSec = int.Parse(Arg(args, "--duration", "0"), CultureInfo.InvariantCulture);
        double? exposureUs = DoubleArg(args, "--exposure");
        double? gain = DoubleArg(args, "--gain");
        double? fps = DoubleArg(args, "--fps");
        long? width = LongArg(args, "--width");
        long? height = LongArg(args, "--height");
        long? centerX = LongArg(args, "--centerx");
        long? centerY = LongArg(args, "--centery");

        Directory.CreateDirectory(outDir);
        string statusPath = Path.Combine(outDir, "latest_status.txt");

        ArenaNET.ISystem system = null;
        ArenaNET.IDevice device = null;
        SharedFramePublisher publisher = null;

        try
        {
            system = ArenaNET.Arena.OpenSystem();
            ListDevices(system);
            if (HasArg(args, "--list"))
                return 0;
            if (system.Devices.Count == 0)
                throw new Exception("No camera connected.");

            device = system.CreateDevice(system.Devices[deviceIndex]);
            var map = device.NodeMap;

            SetEnum(map, "AcquisitionMode", "Continuous");
            SetEnum(map, "ExposureAuto", "Off");
            SetEnum(map, "GainAuto", "Off");
            SetBool(map, "AcquisitionFrameRateEnable", true);
            double configuredFps = SetFloat(map, "AcquisitionFrameRate", fps);
            double maxExposureUs = configuredFps > 0.0
                ? 1000000.0 / configuredFps
                : double.MaxValue;
            if (exposureUs.HasValue)
                exposureUs = Math.Min(exposureUs.Value, maxExposureUs);
            double actualExposureUs = SetFloat(map, "ExposureTime", exposureUs);
            double actualGain = SetFloat(map, "Gain", gain);
            SetEnum(map, "PixelFormat", pixel);

            SetInteger(map, "OffsetX", 0);
            SetInteger(map, "OffsetY", 0);
            long actualWidth = SetInteger(map, "Width", width);
            long actualHeight = SetInteger(map, "Height", height);
            if (width.HasValue || height.HasValue)
            {
                long cx = centerX ?? actualWidth / 2;
                long cy = centerY ?? actualHeight / 2;
                SetInteger(map, "OffsetX", Math.Max(0, cx - actualWidth / 2));
                SetInteger(map, "OffsetY", Math.Max(0, cy - actualHeight / 2));
            }

            SetEnum(device.TLStreamNodeMap, "StreamBufferHandlingMode", "NewestOnly");
            SetBool(device.TLStreamNodeMap, "StreamAutoNegotiatePacketSize", true);
            SetBool(device.TLStreamNodeMap, "StreamPacketResendEnable", true);

            int configuredBpp = BytesPerPixel(pixel);
            long configuredCapacity = actualWidth * actualHeight * configuredBpp;
            if (configuredCapacity <= 0 || configuredCapacity > int.MaxValue)
                throw new Exception("Invalid shared-memory frame capacity.");
            publisher = new SharedFramePublisher(sharedMemoryName,
                (int)configuredCapacity);

            device.StartStream();
            Stopwatch sw = Stopwatch.StartNew();
            long published = 0;
            long dropped = 0;
            DateTime lastControlWriteUtc = DateTime.MinValue;

            while (durationSec <= 0 || sw.Elapsed.TotalSeconds < durationSec)
            {
                if (!string.IsNullOrEmpty(stopFile) && File.Exists(stopFile))
                    break;

                ApplyControlFile(map, controlFile, maxExposureUs,
                    ref lastControlWriteUtc, ref actualExposureUs, ref actualGain);

                ArenaNET.IImage image = null;
                try
                {
                    image = device.GetImage(2000);
                    double nowSec = sw.Elapsed.TotalSeconds;

                    string pf = image.PixelFormat.ToString();
                    int bpp = BytesPerPixel(pf);
                    long expectedBytes = (long)image.Width * (long)image.Height * bpp;
                    byte[] data = image.DataArray;

                    if (data.Length < expectedBytes || image.SizeFilled < expectedBytes)
                    {
                        dropped++;
                        continue;
                    }

                    if (data.Length > expectedBytes)
                    {
                        byte[] trimmed = new byte[expectedBytes];
                        Buffer.BlockCopy(data, 0, trimmed, 0, (int)expectedBytes);
                        data = trimmed;
                    }

                    published++;
                    publisher.Publish(data, (int)image.Width, (int)image.Height,
                        bpp, image.TimestampNs, published, dropped,
                        actualExposureUs, actualGain, configuredFps,
                        published / Math.Max(0.001, nowSec));
                }
                finally
                {
                    if (image != null)
                        device.RequeueBuffer(image);
                }
            }

            TryAtomicWriteText(statusPath, "stopped" + Environment.NewLine + "frameCount=" + published + Environment.NewLine);
            return 0;
        }
        catch (Exception ex)
        {
            string msg = ex.GetType().FullName + ": " + ex.Message;
            try { AtomicWriteText(statusPath, "error" + Environment.NewLine + msg); } catch { }
            Console.Error.WriteLine(msg);
            return 1;
        }
        finally
        {
            if (publisher != null)
                publisher.Dispose();
            if (device != null)
            {
                try { device.StopStream(); } catch { }
                try { system.DestroyDevice(device); } catch { }
            }
            if (system != null)
                ArenaNET.Arena.CloseSystem(system);
        }
    }
}
