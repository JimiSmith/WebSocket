// Frame.swift
//
// The MIT License (MIT)
//
// Copyright (c) 2015 Zewo
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

//	0                   1                   2                   3
//	0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
//	+-+-+-+-+-------+-+-------------+-------------------------------+
//	|F|R|R|R| opcode|M| Payload len |    Extended payload length    |
//	|I|S|S|S|  (4)  |A|     (7)     |             (16/64)           |
//	|N|V|V|V|       |S|             |   (if payload len==126/127)   |
//	| |1|2|3|       |K|             |                               |
//	+-+-+-+-+-------+-+-------------+ - - - - - - - - - - - - - - - +
//	|     Extended payload length continued, if payload len == 127  |
//	+ - - - - - - - - - - - - - - - +-------------------------------+
//	|                               |Masking-key, if MASK set to 1  |
//	+-------------------------------+-------------------------------+
//	| Masking-key (continued)       |          Payload Data         |
//	+-------------------------------- - - - - - - - - - - - - - - - +
//	:                     Payload Data continued ...                :
//	+ - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - +
//	|                     Payload Data continued ...                |
//	+---------------------------------------------------------------+

struct Frame {
    private static let finMask: UInt8 = 0b10000000
    private static let rsv1Mask: UInt8 = 0b01000000
    private static let rsv2Mask: UInt8 = 0b00100000
    private static let rsv3Mask: UInt8 = 0b00010000
    private static let opCodeMask: UInt8 = 0b00001111

    private static let maskMask: UInt8 = 0b10000000
    private static let payloadLenMask: UInt8 = 0b01111111

    enum OpCode: UInt8 {
        case continuation	= 0x0
        case text			= 0x1
        case binary			= 0x2
        // 0x3 -> 0x7 reserved
        case close			= 0x8
        case ping			= 0x9
        case pong			= 0xA
        // 0xB -> 0xF reserved
        case invalid        = 0x10

        var isControl: Bool {
            return self == .close || self == .ping || self == .pong
        }
    }

    var fin: Bool {
        return data[0] & Frame.finMask != 0
    }

    var rsv1: Bool {
        return data[0] & Frame.rsv1Mask != 0
    }

    var rsv2: Bool {
        return data[0] & Frame.rsv2Mask != 0
    }

    var rsv3: Bool {
        return data[0] & Frame.rsv3Mask != 0
    }

    var opCode: OpCode {
        if let opCode = OpCode(rawValue: data[0] & Frame.opCodeMask) {
            return opCode
        }
        return .invalid
    }

    var masked: Bool {
        return data[1] & Frame.maskMask != 0
    }

    var payloadLength: UInt64 {
        return UInt64(data[1] & Frame.payloadLenMask)
    }

    var payload: Data {
        var offset = 2

        if payloadLength == 126 {
            offset += 2
        } else if payloadLength == 127 {
            offset += 8
        }

        if masked {
            offset += 4

            var unmaskedPayloadData = Data(data[offset ..< data.count])

            var maskOffset = 0
            let maskKey = self.maskKey
            for i in 0 ..< unmaskedPayloadData.count {
                unmaskedPayloadData[i] ^= maskKey[maskOffset % 4]
                maskOffset += 1
            }

            return unmaskedPayloadData
        }

        return Data(data[offset ..< data.count])
    }

    var isComplete: Bool {
        switch data.count {
        case 0..<2,
             0..<4 where payloadLength == 126,
             0..<10 where payloadLength == 127: return false
        case let count: return UInt64(count) >= totalFrameSize
        }
    }

    private var extendedPayloadLength: UInt64 {
        if payloadLength == 126 {
            return data.toInt(size: 2, offset: 2)
        } else if payloadLength == 127 {
            return data.toInt(size: 8, offset: 2)
        }
        return payloadLength
    }

    private var maskKey: Data {
        if payloadLength <= 125 {
            return Data(data[2 ..< 6])
        } else if payloadLength == 126 {
            return Data(data[4 ..< 8])
        }
        return Data(data[10 ..< 14])
    }

    private var totalFrameSize: UInt64 {
        let extendedPayloadExtraBytes = (payloadLength == 126 ? 2 : (payloadLength == 127 ? 8 : 0))
        let maskBytes = masked ? 4 : 0
        return UInt64(2 + extendedPayloadExtraBytes + maskBytes) + extendedPayloadLength
    }

    private(set) var data = Data()

    init() {}

    init(opCode: OpCode, data: Data, maskKey: Data) {
        self.data.append((1 << 7) | (0 << 6) | (0 << 5) | (0 << 4) | opCode.rawValue)

        let masked = maskKey.count == 4
        let payloadLength = UInt64(data.count)

        if payloadLength > UInt64(UInt16.max) {
            self.data.append((masked ? 1 : 0) << 7 | 127)
            self.data += Data(number: payloadLength)
        } else if payloadLength > 125 {
            self.data.append((masked ? 1 : 0) << 7 | 126)
            self.data += Data(number: UInt16(payloadLength))
        } else {
            self.data.append((masked ? 1 : 0) << 7 | (UInt8(payloadLength) & 0x7F))
        }
        if masked {
            self.data += maskKey

            var maskedData = data

            var maskOffset = 0
            for i in 0..<maskedData.count {
                maskedData[i] ^= maskKey[maskOffset % 4]
                maskOffset += 1
            }

            self.data += maskedData
        } else {
            self.data += data
        }
    }

    mutating func add(data: Data) -> Data {
        self.data += data

        if isComplete {
            // Int(totalFrameSize) cast is bad, will break spec max frame size of UInt64
            let remainingData = Data(self.data[Int(totalFrameSize)..<self.data.count])
            self.data = Data(self.data[0..<Int(totalFrameSize)])
            return remainingData
        }

        return Data()
    }

}

extension Sequence where Self.Iterator.Element == Frame {
    var payload: Data {
        var payload = Data()

        for frame in self {
            payload += frame.payload
        }

        return payload
    }
}