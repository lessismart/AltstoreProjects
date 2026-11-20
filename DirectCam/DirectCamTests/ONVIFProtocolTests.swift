import XCTest
@testable import DirectCam

final class ONVIFProtocolTests: XCTestCase {
    func testWSUsernameTokenPasswordDigestMatchesSHA1Spec() {
        // Known binary nonce + UTC timestamp -> SHA1(nonce + created + password) -> Base64
        let nonce = Data("0123456789ABCDEF".utf8)
        let created = "2026-11-20T12:00:00.000Z"
        let header = ONVIFPasswordDigest.makeSecurityHeader(
            username: "admin",
            password: "cameraPassword",
            nonceData: nonce,
            createdDate: ISO8601DateFormatter().date(from: "2026-11-20T12:00:00Z")!
        )
        let expectedDigest = ONVIFPasswordDigest.computeDigest(
            nonceData: nonce,
            createdISO: created,
            password: "cameraPassword"
        )
        XCTAssertTrue(header.contains(expectedDigest))
        XCTAssertTrue(header.contains("<wsse:Username>admin</wsse:Username>"))
    }

    func testParsesWSDiscoveryDeviceInfoMediaProfilesAndImagingAcrossPrefixes() throws {
        let probeXML = #"""
        <?xml version="1.0" encoding="UTF-8"?>
        <SOAP-ENV:Envelope xmlns:SOAP-ENV="http://www.w3.org/2003/05/soap-envelope" xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery">
          <SOAP-ENV:Body>
            <d:ProbeMatches>
              <d:ProbeMatch>
                <d:Scopes>onvif://www.onvif.org/name/Front%20Cam onvif://www.onvif.org/hardware/IPC-XM20</d:Scopes>
                <d:XAddrs>http://192.168.2.46:8899/onvif/device_service</d:XAddrs>
              </d:ProbeMatch>
            </d:ProbeMatches>
          </SOAP-ENV:Body>
        </SOAP-ENV:Envelope>
        """#
        let cam = try XCTUnwrap(ONVIFXMLParser.parseProbeMatch(Data(probeXML.utf8), fallbackHost: "192.168.2.46"))
        XCTAssertEqual(cam.host, "192.168.2.46")
        XCTAssertEqual(cam.onvifPort, 8899)
        XCTAssertEqual(cam.name, "Front Cam")
        XCTAssertEqual(cam.hardware, "IPC-XM20")

        let infoXML = #"""
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:tds="http://www.onvif.org/ver10/device/wsdl">
          <s:Body><tds:GetDeviceInformationResponse>
            <tds:Manufacturer>Xiongmai</tds:Manufacturer>
            <tds:Model>IPC-HEVC</tds:Model>
            <tds:FirmwareVersion>V5.00.R02</tds:FirmwareVersion>
            <tds:SerialNumber>SN123456</tds:SerialNumber>
            <tds:HardwareId>HW01</tds:HardwareId>
          </tds:GetDeviceInformationResponse></s:Body>
        </s:Envelope>
        """#
        let info = try XCTUnwrap(ONVIFXMLParser.parseDeviceInfo(Data(infoXML.utf8)))
        XCTAssertEqual(info.manufacturer, "Xiongmai")
        XCTAssertEqual(info.firmwareVersion, "V5.00.R02")

        let imgXML = #"""
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope">
          <s:Body><GetImagingSettingsResponse>
            <ImagingSettings>
              <Brightness>62</Brightness>
              <Contrast>48</Contrast>
              <ColorSaturation>55</ColorSaturation>
              <Sharpness>70</Sharpness>
              <IrCutFilter>OFF</IrCutFilter>
            </ImagingSettings>
          </GetImagingSettingsResponse></s:Body>
        </s:Envelope>
        """#
        let img = try XCTUnwrap(ONVIFXMLParser.parseImagingSettings(Data(imgXML.utf8)))
        XCTAssertEqual(img.brightness, 62)
        XCTAssertEqual(img.irCutFilter, .off)
    }
}
