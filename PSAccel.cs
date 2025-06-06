// PSAccel.cs
// GPU-accelerated data filtering via Direct3D 11
// Author: Derek Poe (@Derek-Poe), 2025
// Version: 0.1.1

using System;
using System.Runtime.InteropServices;
using System.Collections;
using System.Collections.Generic;
using System.Linq;
using System.Management.Automation;
using System.Reflection;


public static class PSAccel
{
    public static IntPtr Device;
    public static IntPtr Context;
    private static ID3DBlob _pinnedBlob;

    [DllImport("kernel32.dll", CharSet = CharSet.Auto)]
    public static extern void OutputDebugString(string message);

    [DllImport("d3d11.dll", CallingConvention = CallingConvention.StdCall)]
    public static extern int D3D11CreateDevice(
        IntPtr pAdapter,
        int DriverType,
        IntPtr Software,
        int Flags,
        IntPtr pFeatureLevels,
        int FeatureLevels,
        int SDKVersion,
        out IntPtr ppDevice,
        out int pFeatureLevel,
        out IntPtr ppImmediateContext);

    [DllImport("d3dcompiler_47.dll", CallingConvention = CallingConvention.StdCall)]
    public static extern int D3DCompile(
        [MarshalAs(UnmanagedType.LPStr)] string srcData,
        int srcDataSize,
        IntPtr fileName,
        IntPtr defines,
        IntPtr include,
        [MarshalAs(UnmanagedType.LPStr)] string entryPoint,
        [MarshalAs(UnmanagedType.LPStr)] string target,
        int flags1,
        int flags2,
        out IntPtr code,
        out IntPtr errorMsgs);

    [ComImport]
    [Guid("8BA5FB08-5195-40e2-AC58-0D989C3A0102")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface ID3DBlob
    {
        [PreserveSig]
        IntPtr GetBufferPointer();

        [PreserveSig]
        IntPtr GetBufferSize(); // <- return IntPtr, not int
    }

    [StructLayout(LayoutKind.Explicit, Pack = 4)]
    public struct D3D11_BUFFER_DESC
    {
        [FieldOffset(0)] public uint ByteWidth;
        [FieldOffset(4)] public uint Usage;
        [FieldOffset(8)] public uint BindFlags;
        [FieldOffset(12)] public uint CPUAccessFlags;
        [FieldOffset(16)] public uint MiscFlags;
        [FieldOffset(20)] public uint StructureByteStride;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    public struct D3D11_SUBRESOURCE_DATA
    {
        public IntPtr pSysMem;
        public uint SysMemPitch;
        public uint SysMemSlicePitch;
    }

    [StructLayout(LayoutKind.Explicit, Pack = 4, Size = 20)]
    public struct D3D11_UNORDERED_ACCESS_VIEW_DESC
    {
        [FieldOffset(0)] public int Format;
        [FieldOffset(4)] public int ViewDimension;
        [FieldOffset(8)] public uint Buffer_FirstElement;
        [FieldOffset(12)] public uint Buffer_NumElements;
        [FieldOffset(16)] public uint Buffer_Flags;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct D3D11_MAPPED_SUBRESOURCE
    {
        public IntPtr pData;
        public uint RowPitch;
        public uint DepthPitch;
    }

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int CreateBufferDelegate(IntPtr device, IntPtr pDesc, IntPtr pData, out IntPtr buffer);

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int CreateUAVDelegate(IntPtr device, IntPtr pResource, IntPtr pDesc, out IntPtr ppUAV);

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int CreateComputeShaderDelegate(
        IntPtr device,
        IntPtr pShaderBytecode,
        IntPtr bytecodeLength,
        IntPtr pClassLinkage,
        out IntPtr ppComputeShader);

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate void CSSetShaderDelegate(IntPtr context, IntPtr shader, IntPtr[] ppClassInstances, uint numClassInstances);

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate void CSSetUAVsDelegate(IntPtr context, uint startSlot, uint numViews, IntPtr[] ppUAVs, uint[] pUAVInitialCounts);

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate void DispatchDelegate(IntPtr context, uint x, uint y, uint z);

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate void CopyResourceDelegate(IntPtr context, IntPtr dstResource, IntPtr srcResource);

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int MapDelegate(IntPtr context, IntPtr resource, uint subresource, uint mapType, uint mapFlags, out D3D11_MAPPED_SUBRESOURCE mappedResource);

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate void UnmapDelegate(IntPtr context, IntPtr resource, uint subresource);

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int CreateSRVDelegate(IntPtr device, IntPtr pResource, IntPtr pDesc, out IntPtr ppSRV);

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate void CSSetSRVsDelegate(IntPtr context, uint startSlot, uint numViews, IntPtr[] ppSRVs);

    public static void Init()
    {
        if (Device != IntPtr.Zero && Context != IntPtr.Zero) return;

        int fl;
        int Flags = 0x2; // D3D11_CREATE_DEVICE_DEBUG
        int hr = D3D11CreateDevice(IntPtr.Zero, 1, IntPtr.Zero, Flags, IntPtr.Zero, 0, 7, out Device, out fl, out Context);

        if (hr != 0)
            throw new Exception("D3D11CreateDevice failed: 0x" + hr.ToString("X"));

        OutputDebugString(">> D3D11CreateDevice succeeded. Feature Level: 0x" + fl.ToString("X"));
    }

    public static IntPtr GetMethod(IntPtr comObject, int vtableIndex)
    {
        IntPtr vtable = Marshal.ReadIntPtr(comObject);
        return Marshal.ReadIntPtr(vtable, vtableIndex * IntPtr.Size);
    }

    public static IntPtr CompileShader(string hlsl, out int size, out ID3DBlob blob)
    {
        IntPtr code;
        IntPtr errors;

        OutputDebugString(">> Shader code length: " + hlsl.Length);
        int hr = D3DCompile(hlsl, hlsl.Length, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero,
                            "CSMain", "cs_5_0", 0, 0, out code, out errors);

        string msg = errors != IntPtr.Zero ? Marshal.PtrToStringAnsi(errors) : "No error string.";
        OutputDebugString(">> Shader compile result: 0x" + hr.ToString("X"));
        OutputDebugString(">> Shader compile message: " + msg);

        if (hr != 0 || code == IntPtr.Zero)
            throw new Exception("Shader compile failed: 0x" + hr.ToString("X") + " - " + msg);

        blob = (ID3DBlob)Marshal.GetObjectForIUnknown(code);
        size = (int)blob.GetBufferSize();
        if (size == 0 || size > 65536)
            OutputDebugString("!! Unexpected shader bytecode size: " + size);

        return blob.GetBufferPointer();
    }

    public static IntPtr CreateBuffer(D3D11_BUFFER_DESC desc, byte[] data = null)
    {
        OutputDebugString(">> Entering CreateBuffer");

        IntPtr descPtr = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(D3D11_BUFFER_DESC)));
        Marshal.StructureToPtr(desc, descPtr, false);

        byte[] rawBytes = new byte[Marshal.SizeOf(desc)];
        Marshal.Copy(descPtr, rawBytes, 0, rawBytes.Length);
        OutputDebugString(">> D3D11_BUFFER_DESC Bytes: " + BitConverter.ToString(rawBytes));

        IntPtr pInitData = IntPtr.Zero;
        IntPtr dataPtr = IntPtr.Zero;

        if (data != null && data.Length > 0)
        {
            dataPtr = Marshal.AllocHGlobal(data.Length);
            Marshal.Copy(data, 0, dataPtr, data.Length);

            D3D11_SUBRESOURCE_DATA initData = new D3D11_SUBRESOURCE_DATA
            {
                pSysMem = dataPtr,
                SysMemPitch = 0,
                SysMemSlicePitch = 0
            };

            pInitData = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(D3D11_SUBRESOURCE_DATA)));
            Marshal.StructureToPtr(initData, pInitData, false);
        }

        IntPtr createBufferPtr = GetMethod(Device, 3); // ID3D11Device::CreateBuffer
        CreateBufferDelegate create = Marshal.GetDelegateForFunctionPointer<CreateBufferDelegate>(createBufferPtr);

        IntPtr buffer;
        int hr = create(Device, descPtr, pInitData, out buffer);

        Marshal.FreeHGlobal(descPtr);
        if (pInitData != IntPtr.Zero) Marshal.FreeHGlobal(pInitData);
        if (dataPtr != IntPtr.Zero) Marshal.FreeHGlobal(dataPtr);

        if (hr != 0)
        {
            OutputDebugString("!! CreateBuffer failed with HRESULT: 0x" + hr.ToString("X"));
            throw new Exception("CreateBuffer failed: 0x" + hr.ToString("X"));
        }

        return buffer;
    }

    public static IntPtr CreateShaderResourceView(IntPtr buffer)
    {
        IntPtr createSRVPtr = GetMethod(Device, 7); // ID3D11Device::CreateShaderResourceView
        CreateSRVDelegate create = Marshal.GetDelegateForFunctionPointer<CreateSRVDelegate>(createSRVPtr);

        // For StructuredBuffer<float>, use null to auto-fill
        IntPtr srv;
        int hr = create(Device, buffer, IntPtr.Zero, out srv);

        if (hr != 0)
        {
            OutputDebugString("!! CreateShaderResourceView failed: 0x" + hr.ToString("X"));
            throw new Exception("CreateShaderResourceView failed: 0x" + hr.ToString("X"));
        }

        OutputDebugString(">> SRV created.");
        return srv;
    }

    public static IntPtr CreateUnorderedAccessView(IntPtr buffer, D3D11_UNORDERED_ACCESS_VIEW_DESC desc)
    {
        int size = Marshal.SizeOf(desc);
        IntPtr ptrDesc = Marshal.AllocHGlobal(size);
        Marshal.StructureToPtr(desc, ptrDesc, false);

        byte[] uavRaw = new byte[Marshal.SizeOf(desc)];
        Marshal.Copy(ptrDesc, uavRaw, 0, uavRaw.Length);
        OutputDebugString(">> UAV_DESC Bytes: " + BitConverter.ToString(uavRaw));

        IntPtr createUAVPtr = GetMethod(Device, 8);
        CreateUAVDelegate create = Marshal.GetDelegateForFunctionPointer<CreateUAVDelegate>(createUAVPtr);

        IntPtr uav;
        int hr = create(Device, buffer, ptrDesc, out uav);

        Marshal.FreeHGlobal(ptrDesc);

        if (hr != 0)
        {
            OutputDebugString("!! CreateUAV failed with HRESULT: 0x" + hr.ToString("X"));
            throw new Exception("CreateUAV failed: 0x" + hr.ToString("X"));
        }

        return uav;
    }

    public static IntPtr CreateComputeShader(IntPtr shaderBytecode, int bytecodeLength)
    {
        IntPtr methodPtr = GetMethod(Device, 18); // VTable index for CreateComputeShader
        CreateComputeShaderDelegate create = Marshal.GetDelegateForFunctionPointer<CreateComputeShaderDelegate>(methodPtr);

        IntPtr computeShader;
        int hr = create(Device, shaderBytecode, (IntPtr)bytecodeLength, IntPtr.Zero, out computeShader);

        if (hr != 0)
        {
            OutputDebugString("!! CreateComputeShader failed with HRESULT: 0x" + hr.ToString("X"));
            throw new Exception("CreateComputeShader failed: 0x" + hr.ToString("X"));
        }

        OutputDebugString(">> CreateComputeShader succeeded.");
        return computeShader;
    }

    public static void SetComputeShader(IntPtr shader)
    {
        IntPtr methodPtr = GetMethod(Context, 69); // VTable index for CSSetShader
        CSSetShaderDelegate setShader = Marshal.GetDelegateForFunctionPointer<CSSetShaderDelegate>(methodPtr);
        setShader(Context, shader, null, 0);
        OutputDebugString(">> Compute shader set.");
    }

    public static void SetSRV(IntPtr srv, uint slot)
    {
        IntPtr methodPtr = GetMethod(Context, 67); // CSSetShaderResources
        CSSetSRVsDelegate setSRVs = Marshal.GetDelegateForFunctionPointer<CSSetSRVsDelegate>(methodPtr);
        setSRVs(Context, slot, 1, new[] { srv });
        OutputDebugString(">> SRV bound to slot t" + slot);
    }

    public static void SetUAV(IntPtr uav, uint slot)
    {
        IntPtr methodPtr = GetMethod(Context, 68); // VTable index for CSSetUnorderedAccessViews
        CSSetUAVsDelegate setUAVs = Marshal.GetDelegateForFunctionPointer<CSSetUAVsDelegate>(methodPtr);
        IntPtr[] uavs = new[] { uav };
        uint[] initialCounts = new uint[] { unchecked((uint)-1) };
        setUAVs(Context, slot, 1, uavs, initialCounts);
        OutputDebugString(">> UAV bound to slot u" + slot);
    }

    public static void Dispatch(uint x, uint y, uint z)
    {
        IntPtr methodPtr = GetMethod(Context, 41); // VTable index for Dispatch
        DispatchDelegate dispatch = Marshal.GetDelegateForFunctionPointer<DispatchDelegate>(methodPtr);
        dispatch(Context, x, y, z);
        OutputDebugString(">> Dispatched with (" + x + ", " + y + ", " + z + ").");
    }

    public static IntPtr CreateStagingBuffer(uint byteWidth)
    {
        D3D11_BUFFER_DESC desc = new D3D11_BUFFER_DESC
        {
            ByteWidth = byteWidth,
            Usage = 3, // D3D11_USAGE_STAGING
            BindFlags = 0,
            CPUAccessFlags = 0x20000, // D3D11_CPU_ACCESS_READ
            MiscFlags = 0,
            StructureByteStride = 0
        };

        return CreateBuffer(desc, new byte[byteWidth]); // no initial data needed
    }

    public static void CopyResource(IntPtr dst, IntPtr src)
    {
        IntPtr methodPtr = GetMethod(Context, 47); // VTable index for CopyResource
        CopyResourceDelegate copy = Marshal.GetDelegateForFunctionPointer<CopyResourceDelegate>(methodPtr);
        copy(Context, dst, src);
        OutputDebugString(">> Resource copied to staging buffer.");
    }

    public static byte[] ReadStagingBuffer(IntPtr buffer, int byteCount)
    {
        IntPtr mapPtr = GetMethod(Context, 14); // Map
        IntPtr unmapPtr = GetMethod(Context, 15); // Unmap

        MapDelegate map = Marshal.GetDelegateForFunctionPointer<MapDelegate>(mapPtr);
        UnmapDelegate unmap = Marshal.GetDelegateForFunctionPointer<UnmapDelegate>(unmapPtr);

        D3D11_MAPPED_SUBRESOURCE mapped;
        int hr = map(Context, buffer, 0, 1, 0, out mapped); // D3D11_MAP_READ = 1

        if (hr != 0)
            throw new Exception("Map failed: 0x" + hr.ToString("X"));

        byte[] data = new byte[byteCount];
        Marshal.Copy(mapped.pData, data, 0, byteCount);

        unmap(Context, buffer, 0);

        OutputDebugString(">> Read back staging buffer to CPU.");
        return data;
    }

    public static PSObject[] RunAccelFilterFromObjects(PSObject[] inputObjects, string[] propertyList, string hlsl)
    {
        if (inputObjects == null || inputObjects.Length == 0)
            return new PSObject[0];

        int rows = inputObjects.Length;
        int cols = propertyList.Length;
        float[] flatData = new float[rows * cols];

        for (int i = 0; i < rows; i++)
        {
            var obj = inputObjects[i];
            for (int ii = 0; ii < cols; ii++)
            {
                var prop = obj.Properties[propertyList[ii]];
                object val = (prop != null) ? prop.Value : null;
                float parsed;
                if (val == null || !float.TryParse(val.ToString(), out parsed))
                {
                    OutputDebugString("[Warning] Property '" + propertyList[ii] + "' invalid on object[" + i + "]");
                    parsed = 0f;
                }

                flatData[i * cols + ii] = parsed;
            }
        }

        int[] mask = RunStructuredFilter(flatData, cols, hlsl);

        PSObject[] results = new PSObject[rows];
        int count = 0;

        for (int i = 0; i < mask.Length; i++)
        {
            if (mask[i] == 1)
                results[count++] = inputObjects[i];
        }

        Array.Resize(ref results, count);
        return results;
    }
    // public static int[] RunAccelFilter(float[] data, string hlsl)
    // {
    //     // Marshal -> structured buffer -> dispatch -> read -> mask output
    //     // Assume this already calls D3DInterop pipeline
    //     return RunStructuredFilter(data, hlsl);
    // }

    public static int[] RunStructuredFilter(float[] flatData, int stride , string hlsl)
    {
        Init();

        const uint D3D11_BIND_SHADER_RESOURCE = 0x8;
        const uint D3D11_BIND_UNORDERED_ACCESS = 0x80;
        const uint D3D11_RESOURCE_MISC_BUFFER_STRUCTURED = 0x40;
        const int DXGI_FORMAT_UNKNOWN = 0;
        const int D3D11_UAV_DIMENSION_BUFFEREX = 1;

        int rowCount = flatData.Length / stride;
        uint bufferLen = (uint)(flatData.Length * sizeof(float));

        // Compile HLSL
        ID3DBlob shaderBlob;
        int shaderSize;
        IntPtr shaderPtr = CompileShader(hlsl, out shaderSize, out shaderBlob);
        _pinnedBlob = shaderBlob;

        // Marshal float[] to byte[]
        byte[] inputBytes = new byte[flatData.Length * sizeof(float)];
        Buffer.BlockCopy(flatData, 0, inputBytes, 0, inputBytes.Length);

        // Create input buffer (StructuredBuffer<Row>)
        D3D11_BUFFER_DESC inputDesc = new D3D11_BUFFER_DESC
        {
            ByteWidth = bufferLen,
            Usage = 0, // D3D11_USAGE_DEFAULT
            BindFlags = D3D11_BIND_SHADER_RESOURCE,
            CPUAccessFlags = 0,
            MiscFlags = D3D11_RESOURCE_MISC_BUFFER_STRUCTURED,
            StructureByteStride = 4
        };
        IntPtr inputBuffer = CreateBuffer(inputDesc, inputBytes);

        // Create output buffer (RWStructuredBuffer<uint>)
        D3D11_BUFFER_DESC outputDesc = new D3D11_BUFFER_DESC
        {
            ByteWidth = bufferLen,
            Usage = 0,
            BindFlags = D3D11_BIND_UNORDERED_ACCESS,
            CPUAccessFlags = 0,
            MiscFlags = D3D11_RESOURCE_MISC_BUFFER_STRUCTURED,
            StructureByteStride = 4
        };
        IntPtr outputBuffer = CreateBuffer(outputDesc, new byte[bufferLen]);

        // Create UAV for output
        D3D11_UNORDERED_ACCESS_VIEW_DESC outputUAV = new D3D11_UNORDERED_ACCESS_VIEW_DESC
        {
            Format = DXGI_FORMAT_UNKNOWN,
            ViewDimension = D3D11_UAV_DIMENSION_BUFFEREX,
            Buffer_FirstElement = 0,
            Buffer_NumElements = (uint)flatData.Length,
            Buffer_Flags = 0
        };

        IntPtr srvInput = CreateShaderResourceView(inputBuffer);
        IntPtr uavOutput = CreateUnorderedAccessView(outputBuffer, outputUAV);

        // Bind and dispatch
        IntPtr computeShader = CreateComputeShader(shaderPtr, shaderSize);
        SetComputeShader(computeShader);
        SetSRV(srvInput, 0);
        SetUAV(uavOutput, 0);

        Dispatch((uint)Math.Ceiling(rowCount / 256.0), 1, 1);

        // Copy output to CPU
        IntPtr staging = CreateStagingBuffer(bufferLen);
        CopyResource(staging, outputBuffer);
        byte[] rawMask = ReadStagingBuffer(staging, (int)bufferLen);

        OutputDebugString("HLSL: " + hlsl);

        // Convert raw mask to int[]
        int[] result = new int[rowCount];
        for (int i = 0; i < rowCount; i++)
            result[i] = BitConverter.ToInt32(rawMask, i * 4);

        return result;
    }
}