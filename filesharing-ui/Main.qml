// File-sharing plugin — pure QML, no C++ core. Talks to storage_module
// (logos-storage / Codex) directly via the prerelease Basecamp's logos
// JS bridge. Runs in-process with the main app, same single-hop pattern as
// the upstream storage_ui plugin.
//
// Bridge API used (all from the prerelease's view-module-runtime):
//   logos.callModule(moduleId, method, [])            — sync, empty args only
//   logos.callModuleAsync(moduleId, method, args, cb) — async with non-empty args
//   logos.onModuleEvent(moduleId, eventName)          — register a subscription
//   Connections { target: logos
//       function onModuleEventReceived(moduleName, eventName, data) { ... } }
//                                                     — receive events
//
// IPC return values arrive as JSON-encoded strings; we JSON.parse one layer
// before using.

import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15

Item {
    id: root
    width: 720
    height: 900

    // ── State ─────────────────────────────────────────────────────────────
    // 0 = Off, 1 = Starting, 2 = Running, 3 = Error
    property int    storageStatus: 0
    property string lastError:     ""
    // storage_module's init() is documented as "call once per process".
    // Subsequent calls return false ("already initialised") — that's fine,
    // we just need to skip them and go straight to start(). Track that here
    // so a Stop→Start cycle within the same Basecamp run doesn't fail.
    property bool   initDone:      false

    // status: 0=idle, 1=in-flight, 2=done, 3=error
    property var lastUpload:   ({ filename: "", cid: "", bytes: 0, status: 0, error: "" })
    property var lastDownload: ({ destPath: "", cid: "", bytes: 0, status: 0, error: "" })

    // ── Bridge helpers ────────────────────────────────────────────────────

    function callSm(method, args, cb) {
        if (typeof logos === "undefined" || !logos.callModuleAsync) return
        logos.callModuleAsync("storage_module", method, args, cb || function(){})
    }
    function callSmSync(method) {
        if (typeof logos === "undefined" || !logos.callModule) return null
        return logos.callModule("storage_module", method, [])
    }

    // Decode the prerelease IPC's JSON-wrapped return values. Empty / null /
    // parse errors fall back to defaultVal.
    function unwrap(raw, defaultVal) {
        if (raw === null || raw === undefined) return defaultVal
        if (typeof raw !== "string") return raw
        try { return JSON.parse(raw) } catch (e) { return defaultVal }
    }

    // libstorage data dir under the user's HOME. Matches storage_ui's default
    // so the same data dir is reused if both are installed.
    function defaultConfigJson() {
        // Qt.resolvedUrl gives a file URL; strip the scheme to get a plain path.
        // We hard-code ~/.logos_storage/data which is the upstream default.
        return JSON.stringify({
            "data-dir": Qt.application.arguments && Qt.application.arguments.length > 0
                        ? "" : "" /* placeholder */,
            "log-level": "INFO"
        })
    }

    // ── Display helpers ───────────────────────────────────────────────────

    function statusText(s) {
        if (s === 0) return "Off"
        if (s === 1) return "Starting…"
        if (s === 2) return "Running"
        if (s === 3) return "Error"
        return ""
    }
    function statusColor(s) {
        if (s === 2) return "#34a853"
        if (s === 1) return "#fbbc04"
        if (s === 3) return "#ea4335"
        return "#9aa5b1"
    }
    function humanSize(n) {
        if (!n || n <= 0) return "0 B"
        const units = ["B", "KB", "MB", "GB", "TB"]
        let i = 0, v = n
        while (v >= 1024 && i < units.length - 1) { v /= 1024; i++ }
        return v.toFixed(v < 10 && i > 0 ? 1 : 0) + " " + units[i]
    }
    // storage_module 3.x takes plain absolute paths, not file:// URLs.
    function toPath(p) {
        if (!p) return ""
        if (p.indexOf("file://") === 0) return decodeURIComponent(p.substring(7))
        return p
    }

    // ── Lifecycle: subscribe to storage_module events on load ─────────────
    // The prerelease's bridge:
    //   logos.onModuleEvent(moduleId, eventName)      — registers the subscription
    //   Connections { target: logos                    — events arrive on the
    //       function onModuleEventReceived(            "moduleEventReceived" signal
    //           moduleName, eventName, data) { ... } } with the data payload
    // Passing a callback as a 3rd arg to onModuleEvent is silently dropped
    // ("Too many arguments, ignoring 1") — the call still registers but no
    // events ever reach a per-call handler, so route everything through the
    // Connections block below.

    Connections {
        target: typeof logos !== "undefined" ? logos : null
        function onModuleEventReceived(moduleName, eventName, data) {
            if (moduleName !== "storage_module") return
            handleStorageEvent(eventName, data)
        }
    }

    Component.onCompleted: {
        if (typeof logos === "undefined" || !logos.onModuleEvent) {
            console.log("filesharing: logos.onModuleEvent not available — events disabled")
            return
        }
        logos.onModuleEvent("storage_module", "storageStart")
        logos.onModuleEvent("storage_module", "storageStop")
        logos.onModuleEvent("storage_module", "storageUploadProgress")
        logos.onModuleEvent("storage_module", "storageUploadDone")
        logos.onModuleEvent("storage_module", "storageDownloadProgress")
        logos.onModuleEvent("storage_module", "storageDownloadDone")
    }

    // storage_module 3.x sends each event as one JSON object, e.g.
    //   storageUploadDone   {"success":true,"sessionId":"0","cid":"zDv…"}
    //   storageUploadProgress {"success":true,"sessionId":"0","bytes":…,"total":…}
    // Older builds sent positional lists: [success, sessionId, cidOrError].
    // Normalise both into { success, cid, error, bytes, total }.
    function eventPayload(data) {
        if (typeof data === "string") {
            try { data = JSON.parse(data) } catch (e) { return { success: false, error: data } }
        }
        // The bridge's QVariantList is list-like but not always a JS Array.
        if (data && data.length === 1 && typeof data[0] === "string") {
            try { data = JSON.parse(data[0]) } catch (e) { /* keep list */ }
        }
        if (data && typeof data === "object" && data.length === undefined) {
            return {
                success: data.success === true || data.success === "true",
                cid: data.cid || "",
                error: data.error || data.message || "",
                bytes: Number(data.bytes || 0),
                total: Number(data.total || 0)
            }
        }
        const list = data || []
        return {
            success: list[0] === true || list[0] === "true",
            cid: list[2] || list[1] || "",
            error: list[2] || list[1] || "",
            bytes: Number(list[2] || 0),
            total: 0
        }
    }

    function handleStorageEvent(eventName, data) {
        const e = eventPayload(data)
        if (eventName === "storageStart") {
            if (e.success) { storageStatus = 2; lastError = "" }
            else           { storageStatus = 3; lastError = e.error || "storage failed to start" }
        } else if (eventName === "storageStop") {
            storageStatus = 0
        } else if (eventName === "storageUploadProgress") {
            if (lastUpload.status !== 1) return
            const upd = lastUpload
            upd.bytes = e.total ? Math.min(e.bytes, e.total) : upd.bytes + e.bytes
            lastUpload = upd
        } else if (eventName === "storageUploadDone") {
            if (lastUpload.status !== 1) return
            const upd = lastUpload
            if (e.success && e.cid) {
                upd.cid = e.cid
                upd.status = 2
            } else {
                upd.error = e.error || "upload failed"
                upd.status = 3
            }
            lastUpload = upd
        } else if (eventName === "storageDownloadProgress") {
            if (lastDownload.status !== 1) return
            const upd = lastDownload
            upd.bytes = e.total ? Math.min(e.bytes, e.total) : upd.bytes + e.bytes
            lastDownload = upd
        } else if (eventName === "storageDownloadDone") {
            if (lastDownload.status !== 1) return
            const upd = lastDownload
            if (e.success) {
                upd.status = 2
            } else {
                upd.error = e.error || "download failed"
                upd.status = 3
            }
            lastDownload = upd
        }
    }

    // ── Actions ───────────────────────────────────────────────────────────

    function startStorage() {
        if (storageStatus === 1 || storageStatus === 2) return
        storageStatus = 1
        lastError = ""

        // Join the same network as the seed-storage seeder so its CIDs resolve.
        // Without bootstrap nodes the storage node is isolated (no peers) and
        // remote CIDs never download. SPRs mirror the seeder's config.json;
        // ports differ from the seeder's (8081/8091) so both run on one machine.
        const cfg = JSON.stringify({
            "log-level": "INFO",
            "listen-port": 8082,
            "disc-port": 8092,
            "bootstrap-node": [
                "spr:CiUIAhIhAlPbmW9J08tDI6pIV-C-XvvFTCDN_Vih8I3ZTOeOuf5rEgIDARo8CicAJQgCEiECU9uZb0nTy0MjqkhX4L5e-8VMIM39WKHwjdlM5465_msQ9tr10QYaCwoJBKX1-QWRAh-aKkcwRQIhAN5zU6DDxSpzqvbFa_iuliroxBx7m86wOO9C1AcKOBqRAiAW3yEXyXtSgXXWzarU_j7E0Ad6HsVAOEvdrpX9FB-i7g",
                "spr:CiUIAhIhA4_xqh_E3HDnV4Gbe159LCAuv03UxcDoGloH1Dhoqy_qEgIDARo8CicAJQgCEiEDj_GqH8TccOdXgZt7Xn0sIC6_TdTFwOgaWgfUOGirL-oQltv10QYaCwoJBKRc8f2RAh-aKkcwRQIhAMWsLt8S694icCKGEH5IB4SyIqUiNNgMmzGJ8n4Wl8udAiB8j3R62SceuRDxBT--scWKN2i22-OT_6-wF0r1Md5kVg",
                "spr:CiUIAhIhAj5vZtyN69MB1cmKhnbxlUo4sp7KfeK1sMipjKpBD47dEgIDARo8CicAJQgCEiECPm9m3I3r0wHVyYqGdvGVSjiynsp94rWwyKmMqkEPjt0Qltv10QYaCwoJBC5lcMmRAh-aKkcwRQIhAPAJt1EiI4pCnLQUivbEs2cSHhE6LPJZYzvVrE1vlf0vAiBCN5nTObJmQGtP4H5d_h5uk_7l0iYPI6Pz0eG33CXrJQ",
                "spr:CiUIAhIhAgX6x7NWUskBQ1a5CvhQ9qe6nAcgE-C6GLjAfnpyRK_6EgIDARo8CicAJQgCEiECBfrHs1ZSyQFDVrkK-FD2p7qcByAT4LoYuMB-enJEr_oQltv10QYaCwoJBKX194aRAh-aKkYwRAIgUhSpUddgFvvs5qO0DncAzfr2lwPl_DdjuhUM0icRiMQCIH3rhiOEBoNXAW9GzsI0GR9WpUEqk15Ij8-SeHqTFOpm"
            ]
        })
        // Helper — interpret the init/start return shape: plain bool from
        // storage_module's current build, or LogosResult struct in newer ones.
        function interpretBoolResult(raw) {
            const r = unwrap(raw, null)
            if (r === true)  return true
            if (r === false) return false
            if (r && r.success === true) return true
            return false
        }

        function callStartAfterInit() {
            callSm("start", [], function(startRaw) {
                const startOk = interpretBoolResult(startRaw)
                if (!startOk) {
                    storageStatus = 3
                    lastError = "storage_module.start() returned false"
                    return
                }
                if (storageStatus === 1) storageStatus = 2
            })
        }

        // Basecamp 0.3 starts its bundled storage node at launch. If it is
        // already running, just use it.
        if (interpretBoolResult(callSmSync("isRunning"))) {
            storageStatus = 2
            return
        }

        // Skip init on subsequent Starts within the same Basecamp run —
        // storage_module's init is once-per-process. start() can be called
        // any number of times.
        if (initDone) {
            callStartAfterInit()
            return
        }

        // init() is once per process; if Basecamp already did it, it reports
        // "already initialised" (false) and start() still works.
        callSm("init", [cfg], function(initRaw) {
            initDone = true
            callStartAfterInit()
        })
    }

    function stopStorage() {
        if (storageStatus !== 2) return
        callSm("stop", [], function() { storageStatus = 0 })
    }

    function uploadFile(path) {
        if (storageStatus !== 2) return
        const filePath = toPath(path)
        if (!filePath) return
        const filename = filePath.split("/").pop()
        lastUpload = { filename: filename, cid: "", bytes: 0, status: 1, error: "" }
        // uploadUrl(filePath, chunkSize, advertise): advertise so peers can fetch it
        callSm("uploadUrl", [filePath, 65536, true], function(_r) {
            // sessionId is in r if we wanted it; the CID arrives via the
            // storageUploadDone event handler above.
        })
    }

    function downloadFile(cid, dest) {
        if (storageStatus !== 2) return
        if (!cid || !dest) return
        const destPath = toPath(dest)
        lastDownload = { destPath: destPath, cid: cid, bytes: 0, status: 1, error: "" }
        // downloadToUrl(cid, filePath, local, chunkSize, isPrivate, advertise)
        callSm("downloadToUrl", [cid, destPath, false, 65536, false, true], function(_r) {})
    }


    // ── Layout ────────────────────────────────────────────────────────────

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 20
        spacing: 14

        // Header
        RowLayout {
            Layout.fillWidth: true
            spacing: 10
            Text {
                text: "File sharing"
                font.pixelSize: 24
                font.weight: Font.DemiBold
                Layout.fillWidth: true
            }
            Rectangle { width: 10; height: 10; radius: 5; color: statusColor(storageStatus) }
            Text {
                text: statusText(storageStatus)
                color: "#444"
                font.pixelSize: 13
            }
            Button {
                text: storageStatus === 0 || storageStatus === 3 ? "Start" : "Stop"
                onClicked: {
                    if (storageStatus === 0 || storageStatus === 3) startStorage()
                    else                                             stopStorage()
                }
            }
        }

        // Error banner
        Rectangle {
            Layout.fillWidth: true
            visible: lastError.length > 0
            color: "#fde7e9"
            border.color: "#ea4335"
            border.width: 1
            radius: 6
            Layout.preferredHeight: errCol.implicitHeight + 20

            ColumnLayout {
                id: errCol
                anchors.fill: parent
                anchors.margins: 10
                spacing: 4
                Text { text: "Storage error"; color: "#b3261e"; font.weight: Font.DemiBold; font.pixelSize: 12 }
                Text {
                    Layout.fillWidth: true
                    text: lastError
                    color: "#5f1f1a"
                    font.pixelSize: 11
                    font.family: "monospace"
                    wrapMode: Text.WordWrap
                }
            }
        }

        // Upload card
        Rectangle {
            Layout.fillWidth: true
            color: "#f8f9fa"
            border.color: "#dfe3e8"
            border.width: 1
            radius: 6
            Layout.preferredHeight: uploadCol.implicitHeight + 24

            ColumnLayout {
                id: uploadCol
                anchors.fill: parent
                anchors.margins: 12
                spacing: 8

                Text { text: "Upload"; font.pixelSize: 16; font.weight: Font.DemiBold }
                Text {
                    text: "Paste a file path or drag a file from Finder into the field below, then Upload."
                    color: "#666"; font.pixelSize: 11
                    Layout.fillWidth: true; wrapMode: Text.WordWrap
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: uploadPathField.implicitHeight + 12
                    color: uploadDrop.containsDrag ? "#e8f0fe" : "transparent"
                    border.color: uploadDrop.containsDrag ? "#1a73e8" : "#dfe3e8"
                    border.width: 1
                    radius: 4

                    TextField {
                        id: uploadPathField
                        anchors.fill: parent
                        anchors.margins: 2
                        placeholderText: "/absolute/path/to/file  —  or drag one here"
                        font.pixelSize: 12
                        selectByMouse: true
                        background: null
                    }
                    DropArea {
                        id: uploadDrop
                        anchors.fill: parent
                        onDropped: (drop) => {
                            if (drop.hasUrls && drop.urls.length > 0) {
                                uploadPathField.text = drop.urls[0].toString()
                                drop.acceptProposedAction()
                            }
                        }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Button {
                        text: "Upload"
                        enabled: storageStatus === 2 && uploadPathField.text.trim().length > 0
                        onClicked: uploadFile(uploadPathField.text.trim())
                    }
                    Text {
                        text: lastUpload.filename
                              ? lastUpload.filename + "  —  " + humanSize(lastUpload.bytes)
                              : "no upload yet"
                        color: "#555"
                        font.pixelSize: 12
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                    }
                }

                ProgressBar {
                    Layout.fillWidth: true
                    indeterminate: lastUpload.status === 1
                    value: lastUpload.status === 2 ? 1 : 0
                    visible: lastUpload.status === 1 || lastUpload.status === 2
                }

                RowLayout {
                    Layout.fillWidth: true
                    visible: !!lastUpload.cid && lastUpload.cid.length > 0
                    spacing: 8

                    Text { text: "CID:"; color: "#666"; font.pixelSize: 12 }
                    TextField {
                        id: cidOutField
                        Layout.fillWidth: true
                        text: lastUpload.cid || ""
                        readOnly: true
                        font.family: "monospace"
                        font.pixelSize: 11
                        selectByMouse: true
                    }
                    Button {
                        text: "Copy"
                        onClicked: { cidOutField.selectAll(); cidOutField.copy() }
                    }
                }

                Text {
                    visible: lastUpload.status === 3 && lastUpload.error.length > 0
                    text: "Error: " + (lastUpload.error || "")
                    color: "#b3261e"
                    font.pixelSize: 11
                }
            }
        }

        // Download card
        Rectangle {
            Layout.fillWidth: true
            color: "#f8f9fa"
            border.color: "#dfe3e8"
            border.width: 1
            radius: 6
            Layout.preferredHeight: downloadCol.implicitHeight + 24

            ColumnLayout {
                id: downloadCol
                anchors.fill: parent
                anchors.margins: 12
                spacing: 8

                Text { text: "Download"; font.pixelSize: 16; font.weight: Font.DemiBold }

                TextField {
                    id: cidField
                    Layout.fillWidth: true
                    placeholderText: "Paste a CID (zDv…)"
                    font.family: "monospace"
                    font.pixelSize: 12
                    selectByMouse: true
                }
                TextField {
                    id: saveToField
                    Layout.fillWidth: true
                    placeholderText: "/absolute/destination/path.ext"
                    font.pixelSize: 12
                    selectByMouse: true
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Button {
                        text: "Download"
                        enabled: storageStatus === 2 &&
                                 cidField.text.trim().length > 0 &&
                                 saveToField.text.trim().length > 0
                        onClicked: downloadFile(cidField.text.trim(), saveToField.text.trim())
                    }
                    Text {
                        text: lastDownload.destPath
                              ? lastDownload.destPath + "  —  " + humanSize(lastDownload.bytes)
                              : "no download yet"
                        color: "#555"
                        font.pixelSize: 12
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                    }
                }
                ProgressBar {
                    Layout.fillWidth: true
                    indeterminate: lastDownload.status === 1
                    value: lastDownload.status === 2 ? 1 : 0
                    visible: lastDownload.status === 1 || lastDownload.status === 2
                }
            }
        }

        // Spacer so Upload + Download cards don't stretch to fill the window.
        Item { Layout.fillHeight: true }
    }
}
