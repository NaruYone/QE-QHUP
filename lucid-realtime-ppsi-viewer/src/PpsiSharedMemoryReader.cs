using System;
using System.IO.MemoryMappedFiles;
using System.Threading;

namespace PpsiSharedMemory
{
    public sealed class Frame
    {
        public byte[] Data { get; internal set; }
        public int Width { get; internal set; }
        public int Height { get; internal set; }
        public int BytesPerPixel { get; internal set; }
        public long FrameCount { get; internal set; }
        public long Dropped { get; internal set; }
        public double ExposureUs { get; internal set; }
        public double Gain { get; internal set; }
        public double CameraFps { get; internal set; }
        public double AcquisitionFps { get; internal set; }
    }

    public sealed class Reader : IDisposable
    {
        const int Magic = 0x49535050;
        const int HeaderSize = 128;
        readonly MemoryMappedFile map;
        readonly MemoryMappedViewAccessor view;

        public Reader(string name)
        {
            map = MemoryMappedFile.OpenExisting(name,
                MemoryMappedFileRights.Read);
            view = map.CreateViewAccessor(0, 0,
                MemoryMappedFileAccess.Read);
        }

        public Frame ReadLatest(long previousFrameCount)
        {
            for (int attempt = 0; attempt < 3; attempt++)
            {
                long sequence1 = view.ReadInt64(32);
                if (sequence1 == 0 || (sequence1 & 1) != 0)
                {
                    Thread.Yield();
                    continue;
                }
                if (view.ReadInt32(0) != Magic ||
                    view.ReadInt32(8) != HeaderSize)
                    throw new InvalidOperationException(
                        "Invalid RealtimePPSI shared-memory header.");

                int capacity = view.ReadInt32(12);
                int width = view.ReadInt32(16);
                int height = view.ReadInt32(20);
                int bpp = view.ReadInt32(24);
                int activeBuffer = view.ReadInt32(28);
                long frameCount = view.ReadInt64(48);
                long dropped = view.ReadInt64(56);
                double exposureUs = view.ReadDouble(64);
                double gain = view.ReadDouble(72);
                double cameraFps = view.ReadDouble(80);
                double acquisitionFps = view.ReadDouble(88);

                if (frameCount == previousFrameCount)
                    return null;
                long byteCount64 = (long)width * height * bpp;
                if (capacity <= 0 || byteCount64 <= 0 ||
                    byteCount64 > capacity || byteCount64 > int.MaxValue ||
                    activeBuffer < 0 || activeBuffer > 1)
                    throw new InvalidOperationException(
                        "Invalid RealtimePPSI frame dimensions.");

                byte[] data = new byte[(int)byteCount64];
                long dataOffset = HeaderSize + (long)activeBuffer * capacity;
                view.ReadArray(dataOffset, data, 0, data.Length);
                Thread.MemoryBarrier();
                long sequence2 = view.ReadInt64(32);
                if (sequence1 == sequence2 && (sequence2 & 1) == 0)
                {
                    return new Frame {
                        Data = data,
                        Width = width,
                        Height = height,
                        BytesPerPixel = bpp,
                        FrameCount = frameCount,
                        Dropped = dropped,
                        ExposureUs = exposureUs,
                        Gain = gain,
                        CameraFps = cameraFps,
                        AcquisitionFps = acquisitionFps
                    };
                }
            }
            return null;
        }

        public void Dispose()
        {
            view.Dispose();
            map.Dispose();
        }
    }
}
