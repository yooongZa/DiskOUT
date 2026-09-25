import AppKit

@main enum CharacterArtworkTests {
    static func main() throws {
        _ = NSApplication.shared
        guard CommandLine.arguments.count >= 2, let bundle = Bundle(path: CommandLine.arguments[1]) else { fatalError("Pass built app path") }
        let store = StatusCharacterFrameStore(bundle: bundle)
        precondition(store.halloweenArtwork.hasCompleteCollection, "All approved Halloween artwork must ship in the app")
        precondition(store.basicArtwork.hasCompleteCollection, "All 13 basic characters must ship in the app")
        // The individual v2 assets must drive the character store, even without a
        // legacy atlas. Merely copying unused PNGs into the app must not pass.
        let individualNames = ["BasicBicycle", "BasicFox", "HalloweenBicycle", "HalloweenBicycleRest",
            "HalloweenBroom", "HalloweenHound", "HalloweenWeb", "HalloweenScythe", "HalloweenFox"]
        let individualURL = FileManager.default.temporaryDirectory.appendingPathComponent("DiskOUT-artwork-\(UUID().uuidString).bundle")
        let individualResources = individualURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: individualResources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: individualURL) }
        let info: [String: String] = ["CFBundleIdentifier": "com.diskout.artwork-regression.\(UUID().uuidString)", "CFBundlePackageType": "BNDL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: individualURL.appendingPathComponent("Contents/Info.plist"))
        for name in individualNames {
            guard let source = bundle.url(forResource: name, withExtension: "png") else { fatalError("Missing approved individual resource: \(name)") }
            try FileManager.default.copyItem(at: source, to: individualResources.appendingPathComponent("\(name).png"))
        }
        let individualBundle = Bundle(url: individualURL)!
        let individualBasic = BasicArtworkStore(bundle: individualBundle)
        let individualHalloween = HalloweenArtworkStore(bundle: individualBundle)
        for count in [2, 9] {
            precondition(individualBasic.hasArtwork(for: count), "Basic \(count) loads independently of the old atlas")
            precondition(individualBasic.sprite(for: count)!.image.tiffRepresentation == store.basicArtwork.sprite(for: count)!.image.tiffRepresentation,
                "Basic \(count) renders the approved individual artwork when the atlas is present")
        }
        for character in [HalloweenCharacter.staff, .bicycle, .hound, .web, .scythe, .fox] {
            precondition(individualHalloween.hasArtwork(for: character), "\(character) loads independently of the old atlas")
            precondition(individualHalloween.sprite(for: character)!.image.tiffRepresentation == store.halloweenArtwork.sprite(for: character)!.image.tiffRepresentation,
                "\(character) renders the approved individual artwork when the atlas is present")
        }
        let missingStore = StatusCharacterFrameStore(bundle: Bundle(for: NSView.self))
        let missingAnimator = StatusCharacterAnimator(frameStore: missingStore, reduceMotion: { false })
        defer { missingAnimator.invalidate() }
        var missingTicks = 0
        missingAnimator.onFrameChanged = { missingTicks += 1 }
        let missingVisuals: [CharacterVisual] = (0...12).flatMap { count in
            [CharacterVisual.basic(count: count, reactive: false), .basic(count: count, reactive: true)]
        } + HalloweenCharacter.allCases.map { .halloween($0, animated: true) }
        for visual in missingVisuals {
            missingAnimator.configure(visual: visual, state: .active)
            precondition(missingAnimator.currentImage() == nil, "Missing artwork uses the existing numeric fallback")
        }
        // Exercise both branches long enough for an incorrectly started timer to fire.
        for visual in [CharacterVisual.basic(count: 2, reactive: false), .basic(count: 2, reactive: true),
                       .halloween(.fox, animated: true)] {
            missingAnimator.configure(visual: visual, state: .active)
            missingTicks = 0
            RunLoop.main.run(until: Date().addingTimeInterval(0.24))
            precondition(missingTicks == 0, "Missing resources do not keep an animation timer alive")
        }
        var images: [[NSImage]] = []
        let states: [CharacterMotionState] = [.rest, .active, .busy]
        let visuals: [CharacterVisual] = (0...12).map { .basic(count: $0, reactive: true) }
            + HalloweenCharacter.allCases.map { .halloween($0, animated: true) }
        for visual in visuals {
            var row: [NSImage] = []
            for state in states {
                var poses = Set<Data>()
                for frame in 0..<6 {
                    let basic: NSImage?
                    if case .basic(let count, _) = visual { basic = store.image(for: count, frame: state == .rest ? 0 : frame) }
                    else { basic = nil }
                    guard let icon = CharacterArtwork.image(visual: visual, state: state, frame: frame,
                        basicImage: basic, halloweenStore: store.halloweenArtwork, basicStore: store.basicArtwork) else { fatalError("Missing image") }
                    precondition(icon.representations.count == 2 && icon.isTemplate)
                    for representation in icon.representations {
                        let bitmap = representation as! NSBitmapImageRep
                        var ink = 0
                        for x in 0..<bitmap.pixelsWide {
                            for y in 0..<bitmap.pixelsHigh {
                                if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                                    ink += 1
                                    precondition(x > 0 && y > 0 && x < bitmap.pixelsWide - 1 && y < bitmap.pixelsHigh - 1,
                                        "Artwork and motion stay clear of all bitmap edges: \(visual), \(state), frame \(frame), \(bitmap.pixelsWide)px at (\(x), \(y))")
                                }
                            }
                        }
                        precondition(ink > 10 && ink < bitmap.pixelsWide * bitmap.pixelsHigh * 8 / 10, "Artwork must have ink and transparent margin")
                    }
                    poses.insert(icon.tiffRepresentation!)
                    row.append(icon)
                }
                if state != .rest { precondition(poses.count > 1, "Active and busy must move") }
            }
            images.append(row)
        }
        // Remove offsets, amplitude and cyclic phase before comparing movement.
        // The same six keys played faster or farther must not count as a new gait.
        func normalizedCycleDistance(_ active:[[Double]],_ busy:[[Double]]) -> Double {
            let minimumDeviation=[0.02,0.02,0.02,0.004]
            var left:[[Double]]=[],right:[[Double]]=[]
            for feature in 0..<4 {
                let a=active.map {$0[feature]},b=busy.map {$0[feature]}
                func normalize(_ values:[Double]) -> ([Double],Double) {
                    let mean=values.reduce(0,+)/Double(values.count)
                    let deviation=sqrt(values.map {pow($0-mean,2)}.reduce(0,+)/Double(values.count))
                    return (deviation<minimumDeviation[feature] ? Array(repeating:0,count:values.count):values.map {($0-mean)/deviation},deviation)
                }
                let (na,sa)=normalize(a),(nb,sb)=normalize(b)
                if max(sa,sb)>=minimumDeviation[feature] {left.append(na);right.append(nb)}
            }
            guard !left.isEmpty else {return 0}
            return (0..<6).map {shift in
                sqrt(left.indices.reduce(0.0) {total,feature in
                    total+(0..<6).reduce(0.0) {$0+pow(left[feature][$1]-right[feature][($1+shift)%6],2)}
                }/Double(left.count*6))
            }.min()!
        }
        // Both cycles stay visible, while a low sprint is allowed to travel less
        // vertically than a walk or hop. Pixel metrics complement equal-speed review.
        for visual in visuals {
            var motionFeatures:[[[Double]]]=[]
            for state in [CharacterMotionState.active, .busy] {
                var poses1x = Set<Data>(), centersY: [Double] = [], heights: [Double] = []
                var features:[[Double]]=[]
                for frame in 0..<6 {
                    let icon = CharacterArtwork.image(visual: visual, state: state, frame: frame,
                        pose: .init(frame: frame, sleepStep: 0, breathFrame: 0, zFrame: -1),
                        halloweenStore: store.halloweenArtwork, basicStore: store.basicArtwork)!
                    poses1x.insert((icon.representations.first as! NSBitmapImageRep).representation(using: .png, properties: [:])!)
                    let bitmap = icon.representations.last as! NSBitmapImageRep
                    var mass=0.0,weightedY=0.0,weightedX=0.0,xx=0.0,yy=0.0,xy=0.0,minY=bitmap.pixelsHigh,maxY = -1
                    for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
                        let alpha = Double(bitmap.colorAt(x: x, y: y)!.alphaComponent)
                        let px=Double(x)+0.5,py=Double(y)+0.5
                        mass+=alpha;weightedY+=py*alpha;weightedX+=px*alpha
                        xx+=px*px*alpha;yy+=py*py*alpha;xy+=px*py*alpha
                        if alpha > 0.1 { minY = min(minY, y); maxY = max(maxY, y) }
                    }}
                    let cx=weightedX/mass,cy=weightedY/mass
                    let vx=max(0.0001,xx/mass-cx*cx),vy=max(0.0001,yy/mass-cy*cy)
                    features.append([cy/2,sqrt(vx)/2,sqrt(vy)/2,(xy/mass-cx*cy)/sqrt(vx*vy)])
                    centersY.append(weightedY / mass / 2)
                    heights.append(Double(maxY - minY + 1) / 2)
                }
                let verticalSpan = centersY.max()! - centersY.min()!
                let heightSpan = heights.max()! - heights.min()!
                let tilts=features.map {$0[3]},tiltSpan=tilts.max()!-tilts.min()!
                precondition(poses1x.count >= 4, "Lively motion has at least four visible 1x poses: \(visual), \(state)")
                if state == .active && !CharacterArtwork.isBicycle(visual) {
                    precondition(verticalSpan>=0.6 && heightSpan>=0.5,
                        "Active gait retains visible travel and posture changes: \(visual), travel \(verticalSpan)pt, height \(heightSpan)pt")
                } else if !CharacterArtwork.isBicycle(visual) {
                    // A wheelie or sweep can rotate inside the same outer height.
                    precondition(max(verticalSpan,heightSpan)>=0.5 || tiltSpan>=0.08,
                        "Busy gait visibly travels, changes posture or rotates: \(visual), travel \(verticalSpan)pt, height \(heightSpan)pt, tilt \(tiltSpan)")
                }
                motionFeatures.append(features)
            }
            let difference=normalizedCycleDistance(motionFeatures[0],motionFeatures[1])
            precondition(CharacterArtwork.isBicycle(visual) || difference>=0.35,
                "Active and busy have different pose sequences after removing speed, amplitude and cyclic phase: \(visual), normalized distance \(difference)")
        }
        // The larger faces must retain their enclosed white eyes/markings while
        // bouncing. Whole-body transforms preserve these holes; a stale partial
        // sprite crop can cut a face open or erase one of them.
        func enclosedDetails(_ icon: NSImage) -> Int {
            let bitmap=icon.representations.last as! NSBitmapImageRep
            let width=bitmap.pixelsWide,height=bitmap.pixelsHigh
            var clear=[Bool](repeating:false,count:width*height),visited=clear,holes=0
            var minX=width,minY=height,maxX = -1,maxY = -1
            for y in 0..<height {for x in 0..<width {
                let alpha=bitmap.colorAt(x:x,y:y)!.alphaComponent;clear[y*width+x]=alpha<0.5
                if alpha>0.1 {minX=min(minX,x);minY=min(minY,y);maxX=max(maxX,x);maxY=max(maxY,y)}
            }}
            for start in clear.indices where clear[start] && !visited[start] {
                var queue=[start],cursor=0,touchesEdge=false,touchesPawRegion=false;visited[start]=true
                while cursor<queue.count {
                    let pixel=queue[cursor],x=pixel%width,y=pixel/width;cursor+=1
                    if x==0 || y==0 || x==width-1 || y==height-1 {touchesEdge=true}
                    let nx=Double(x-minX)/Double(maxX-minX),ny=Double(y-minY)/Double(maxY-minY)
                    // A white chest connected to the moving front paws can open
                    // to the background without changing eyes, ears or tail cuts.
                    if nx>=0.25 && nx<=0.75 && ny>=0.78 {touchesPawRegion=true}
                    for (dx,dy) in [(-1,0),(1,0),(0,-1),(0,1)] {
                        let nx=x+dx,ny=y+dy
                        guard nx>=0 && ny>=0 && nx<width && ny<height else {continue}
                        let neighbor=ny*width+nx
                        guard clear[neighbor] && !visited[neighbor] else {continue}
                        visited[neighbor]=true;queue.append(neighbor)
                    }
                }
                if !touchesEdge && !touchesPawRegion && queue.count>=16 {holes+=1}
            }
            return holes
        }
        for visual in [CharacterVisual.basic(count:9,reactive:true),.halloween(.fox,animated:true),.halloween(.hound,animated:true)] {
            func detailImage(_ state:CharacterMotionState,_ frame:Int) -> NSImage {
                CharacterArtwork.image(visual:visual,state:state,frame:frame,
                    pose:.init(frame:frame,sleepStep:0,breathFrame:0,zFrame:-1),
                    halloweenStore:store.halloweenArtwork,renderSize:128,basicStore:store.basicArtwork)!
            }
            let details=enclosedDetails(detailImage(.unknown,0))
            precondition(details>0,"Face detail comparison has enclosed source features: \(visual)")
            for state in [CharacterMotionState.active,.busy] {for frame in 0..<6 {
                let renderedDetails=enclosedDetails(detailImage(state,frame))
                precondition(renderedDetails==details,
                    "Run/jump motion keeps white face details intact: \(visual), \(state), frame \(frame): \(renderedDetails) details, expected \(details)")
            }}
        }
        // Inspect actual pixels through settling, breathing, Zzz and waking. Every
        // character is covered because a new silhouette may collide with an old pivot.
        func artworkBounds(_ icon: NSImage, context: String, centered: Bool = false) {
            for representation in icon.representations {
                let bitmap = representation as! NSBitmapImageRep
                var minX = bitmap.pixelsWide, minY = bitmap.pixelsHigh, maxX = -1, maxY = -1
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        guard (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 else { continue }
                        minX = min(minX, x); minY = min(minY, y)
                        maxX = max(maxX, x); maxY = max(maxY, y)
                    }
                }
                let detail = "\(context), \(bitmap.pixelsWide)px, ink bounds (\(minX), \(minY))...(\(maxX), \(maxY))"
                precondition(maxX >= minX && maxY >= minY, "Character has visible artwork: \(detail)")
                precondition(minX > 0 && minY > 0 && maxX < bitmap.pixelsWide - 1 && maxY < bitmap.pixelsHigh - 1,
                    "Character and sleep marks stay clear of the bitmap edges: \(detail)")
                if centered {
                    let inkCenterY = Double(minY + maxY + 1) / 2
                    precondition(abs(inkCenterY - Double(bitmap.pixelsHigh) / 2) <= 1,
                        "Neutral bicycle is vertically centered within one output pixel: \(detail)")
                }
            }
        }
        for visual in visuals {
            func renderCharacter(_ state: CharacterMotionState, pose: CharacterRenderPose) -> NSImage {
                CharacterArtwork.image(visual: visual, state: state, frame: pose.frame, pose: pose,
                    halloweenStore: store.halloweenArtwork, basicStore: store.basicArtwork)!
            }
            let isBicycle = visual == .basic(count: 2, reactive: true) || visual == .halloween(.bicycle, animated: true)
            artworkBounds(renderCharacter(.unknown, pose: .still(state: .unknown)), context: "\(visual) neutral", centered: isBicycle)
            for state in [CharacterMotionState.active, .busy] {
                for frame in 0..<6 {
                    artworkBounds(renderCharacter(state, pose: .still(state: state, frame: frame)),
                        context: "\(visual) \(state) frame \(frame)")
                }
            }
            var timeline = CharacterMotionTimeline()
            timeline.setState(.rest, at: 0, reset: true)
            // Cover settling plus a complete breath and Z cycle with the actual timeline.
            for sample in 0...72 {
                let instant = Double(sample) / 20
                artworkBounds(renderCharacter(.rest, pose: timeline.pose(at: instant)),
                    context: "\(visual) resting at \(instant)")
            }
            for wakingState in [CharacterMotionState.active,.busy] {
                var wakingTimeline=CharacterMotionTimeline()
                wakingTimeline.setState(.rest,at:0,reset:true)
                wakingTimeline.setState(wakingState,at:3.6)
                for sample in 0...8 {
                    let instant = 3.6 + Double(sample) / 20
                    artworkBounds(renderCharacter(wakingState, pose: wakingTimeline.pose(at: instant)),
                        context: "\(visual) waking to \(wakingState) at \(instant)")
                }
            }
        }
        // A rigid bicycle can ride smoothly without bouncing its entire mass.
        // Check its readable width and eight distinct mechanical poses directly.
        for visual in [CharacterVisual.basic(count: 2, reactive: true), .halloween(.bicycle, animated: true)] {
            var stateFrames: [Set<Data>] = []
            for state in [CharacterMotionState.active, .busy] {
                var frames = Set<Data>()
                for f in 0..<8 {
                    let icon = CharacterArtwork.image(visual: visual, state: state, frame: f,
                        halloweenStore: store.halloweenArtwork, basicStore: store.basicArtwork)!
                    precondition(icon.size == NSSize(width: 30, height: 21), "Bicycle has dedicated horizontal space")
                    frames.insert((icon.representations.first as! NSBitmapImageRep).representation(using: .png, properties: [:])!)
                    artworkBounds(icon, context: "Eight-pose bicycle \(visual) \(state) \(f)")
                }
                precondition(frames.count == 8, "Every crank / rider pose is visible at native 1x")
                stateFrames.append(frames)
            }
            precondition(stateFrames[0] != stateFrames[1], "Busy riding has its own posture / passenger cycle")
        }
        func inkComponents(_ bitmap:NSBitmapImageRep,threshold:CGFloat,excludingBottomRows:Int = 0) -> [Int] {
            let width=bitmap.pixelsWide,height=bitmap.pixelsHigh
            var ink=[Bool](repeating:false,count:width*height),visited=ink,areas:[Int]=[]
            for y in 0..<(height-excludingBottomRows) {for x in 0..<width {ink[y*width+x]=bitmap.colorAt(x:x,y:y)!.alphaComponent>threshold}}
            for start in ink.indices where ink[start] && !visited[start] {
                var queue=[start],cursor=0;visited[start]=true
                while cursor<queue.count {
                    let pixel=queue[cursor],px=pixel%width,py=pixel/width;cursor+=1
                    for dy in -1...1 {for dx in -1...1 {
                        let nx=px+dx,ny=py+dy
                        guard nx>=0 && nx<width && ny>=0 && ny<height else {continue}
                        let neighbor=ny*width+nx
                        guard ink[neighbor] && !visited[neighbor] else {continue}
                        visited[neighbor]=true;queue.append(neighbor)
                    }}
                }
                areas.append(queue.count)
            }
            return areas
        }
        // Both large squid tentacles stay attached during the stronger push-off.
        // Tiny source details may be separate; detached arms are substantial islands.
        for state in [CharacterMotionState.active,.busy] {for frame in 0..<6 {
            let image=CharacterArtwork.image(visual:.basic(count:10,reactive:true),state:state,frame:frame,
                pose:.init(frame:frame,sleepStep:0,breathFrame:0,zFrame:-1),halloweenStore:store.halloweenArtwork,
                renderSize:128,basicStore:store.basicArtwork)!
            let areas=inkComponents(image.representations.last as! NSBitmapImageRep,threshold:0.35)
            let significant=Double(areas.reduce(0,+))*0.025
            precondition(areas.filter {Double($0)>=significant}.count==1,
                "Squid push-off retains both large tentacles on the body: \(state) frame \(frame), components \(areas)")
        }}
        // The selected B rider holds the handlebar. Its body and bicycle must
        // remain connected, with no fragments introduced by the sleep/crank masks.
        // Inspect gallery pixels so 1x antialiasing does not hide a broken joint.
        for state in [CharacterMotionState.unknown, .active, .busy] {
            for frame in 0..<8 {
                let icon = CharacterArtwork.image(visual: .halloween(.bicycle, animated: true), state: state, frame: frame,
                    pose: .init(frame: frame, sleepStep: 0, breathFrame: 0, zFrame: -1),
                    halloweenStore: store.halloweenArtwork, renderSize: 64, basicStore: store.basicArtwork)!
                let bitmap = icon.representations.last as! NSBitmapImageRep
                // Exclude the road band (below drawing y=2) from the silhouette
                // count, keeping the rider/body attachment check intact.
                // The 30 x 21 drawing has 4.5 points of padding in a square tile.
                let roadRows = Int(ceil(Double(bitmap.pixelsHigh) * 6.5 / 30))
                let componentAreas=inkComponents(bitmap,threshold:0.3,excludingBottomRows:roadRows)
                precondition(componentAreas.filter { $0 > 4 }.count == 1,
                    "The B rider and bicycle stay attached without mask fragments; \(state) frame \(frame), components \(componentAreas)")
            }
        }
        // The ghost folds onto the saddle while the original bicycle stays unchanged.
        // Freeze breathing and sleep marks so this checks only the folding transition.
        let ghostSleepFrames = (0...8).map { step in
            CharacterArtwork.image(visual: .halloween(.bicycle, animated: true), state: .rest, frame: 0,
                pose: .init(frame: 0, sleepStep: step, breathFrame: 0, zFrame: -1),
                halloweenStore: store.halloweenArtwork, renderSize: 64, basicStore: store.basicArtwork)!
        }
        precondition(Set(ghostSleepFrames.map { $0.tiffRepresentation! }).count >= 7,
            "Halloween ghost descends and folds through distinct intermediate poses")
        for representationIndex in ghostSleepFrames[0].representations.indices {
            let reference = ghostSleepFrames[0].representations[representationIndex] as! NSBitmapImageRep
            var minY = reference.pixelsHigh, maxY = -1
            for y in 0..<reference.pixelsHigh {
                for x in 0..<reference.pixelsWide where (reference.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            // The selected B bike is smaller: its lower wheel/frame band below
            // y=5 stays still while the rider folds above the saddle at y=5.3.
            // Gallery canvases center that drawing vertically in a square tile.
            let firstBikeRow = Int(ceil(Double(reference.pixelsHigh) * (1 - (4.5 + 5) / 30)))
            for image in ghostSleepFrames.dropFirst() {
                let bitmap = image.representations[representationIndex] as! NSBitmapImageRep
                for y in firstBikeRow..<reference.pixelsHigh {
                    for x in 0..<reference.pixelsWide {
                        precondition(bitmap.colorAt(x: x, y: y)?.alphaComponent == reference.colorAt(x: x, y: y)?.alphaComponent,
                            "Folding the ghost preserves the bicycle wheels and frame at \(reference.pixelsWide)px")
                    }
                }
            }
        }
        // Once folded, the former floating-head area is empty. A low alpha
        // threshold catches clipped antialiased fragments that are invisible to
        // the silhouette/edge tests but show as gray dashes on a white menu bar.
        for breath in 0..<12 {
            let folded = CharacterArtwork.image(visual: .halloween(.bicycle, animated: true), state: .rest, frame: 0,
                pose: .init(frame: 0, sleepStep: 8, breathFrame: breath, zFrame: -1),
                halloweenStore: store.halloweenArtwork, basicStore: store.basicArtwork)!
            for case let bitmap as NSBitmapImageRep in folded.representations {
                for y in 0..<(bitmap.pixelsHigh * 2 / 21) { for x in 0..<bitmap.pixelsWide {
                    precondition(bitmap.colorAt(x: x, y: y)!.alphaComponent <= 1.0 / 255,
                        "Folded ghost leaves no old head fragments: \(bitmap.pixelsWide)px, breath \(breath), (\(x), \(y))")
                }}
            }
        }
        let gallery = StatusCharacterAnimator(frameStore: store, renderSize: 64, now: { 0 }, reduceMotion: { false })
        defer { gallery.invalidate() }
        for character in HalloweenCharacter.allCases {
            gallery.configure(visual: .halloween(character, animated: false), state: .unknown)
            let preview = gallery.currentImage()!
            precondition(preview.size == NSSize(width: 64, height: 64))
            precondition(preview.representations.map(\.pixelsWide) == [64, 128], "Gallery renders from the original source at its own resolution")
        }
        for count in 0...12 {
            for reactive in [false, true] {
                gallery.configure(visual: .basic(count: count, reactive: reactive), state: .active)
                let preview = gallery.currentImage()!
                precondition(preview.size == NSSize(width: 64, height: 64))
                precondition(preview.representations.map(\.pixelsWide) == [64, 128],
                    "Free and premium basic previews render from the source at gallery resolution")
                precondition(gallery.currentImage() === preview, "Unchanged preview poses reuse the cache")
            }
            for frame in 0..<6 {
                let pose = CharacterRenderPose(frame: frame, sleepStep: 0, breathFrame: 0, zFrame: -1)
                let free = store.image(for: count, frame: frame)!
                let premium = CharacterArtwork.image(visual: .basic(count: count, reactive: true),
                    state: .active, frame: frame, pose: pose, halloweenStore: store.halloweenArtwork,
                    basicStore: store.basicArtwork)!
                precondition(premium.tiffRepresentation == free.tiffRepresentation,
                    "Free and premium active frames share the refreshed character artwork")
            }
        }
        // Check the live driver with a controlled monotonic clock, including stopped effects.
        var time: TimeInterval = 0
        var reduced = false
        let animator = StatusCharacterAnimator(frameStore: store, now: { time }, reduceMotion: { reduced })
        defer { animator.invalidate() }
        let bicycle: CharacterVisual = .basic(count: 2, reactive: true)
        func pixels() -> Data { animator.currentImage()!.tiffRepresentation! }
        animator.configure(visual: bicycle, state: .rest)
        let upright = pixels()
        time = 0.4; let halfway = pixels()
        time = 1; let asleep = pixels()
        precondition(upright != halfway && halfway != asleep, "bicycle settling into rest has intermediate poses")
        animator.configure(visual: bicycle, state: .rest)
        precondition(pixels() == asleep, "live activity polling preserves the timeline")
        time = 1.7; precondition(pixels() != asleep, "sleep breath and Z continue")
        animator.configure(visual: bicycle, state: .active)
        let waking = pixels(); time = 2.2
        precondition(pixels() != waking, "bicycle wakes from its resting pose")
        reduced = true
        let stopped = pixels(); time = 3.7
        precondition(pixels() == stopped, "Reduce Motion freezes every effect")
        reduced = false
        animator.configure(visual: .halloween(.fox, animated: false), state: .rest)
        let manualOff = pixels(); time = 5
        precondition(pixels() == manualOff, "manual off freezes Halloween including Z")
        animator.configure(visual: .halloween(.spider, animated: true), state: .unknown)
        let unknown = pixels(); time = 7
        precondition(pixels() == unknown, "unknown stays neutral")
        animator.configure(visual: bicycle, state: .rest)
        animator.setActive(false)
        let hidden = pixels(); time = 9
        precondition(pixels() == hidden, "hidden preview freezes every effect")
        animator.configure(visual: .numbers, state: .busy)
        precondition(animator.currentImage() == nil, "numeric display has no animated image")
        animator.configure(visual: .basic(count: 2, reactive: false), state: .rest)
        precondition(pixels() == store.image(for: 2, frame: 0)!.tiffRepresentation!, "free bicycle reuses the refreshed cached frame")
        animator.configure(visual: bicycle, state: .rest)
        let center = NSWorkspace.shared.notificationCenter
        for pair in [(NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification),
                     (NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification)] {
            center.post(name: pair.0, object: nil)
            let paused = pixels(); time += 1
            precondition(pixels() == paused, "sleep notification stops rendering effects")
            var ticks = 0
            animator.onFrameChanged = { ticks += 1 }
            RunLoop.main.run(until: Date().addingTimeInterval(0.24))
            precondition(ticks == 0, "sleep stops timer callbacks")
            center.post(name: pair.1, object: nil)
            ticks = 0
            RunLoop.main.run(until: Date().addingTimeInterval(0.24))
            precondition(ticks > 0, "wake resumes the single animation timer")
        }
        if CommandLine.arguments.count > 2 {
            let width = 1050, height = 850
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            NSColor.white.setFill(); NSRect(x: 0, y: 0, width: width, height: height).fill()
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black]
            for (index, row) in images.enumerated() {
                let y = CGFloat(height - 55 - index * 34)
                let title = index < 13 ? "Basic \(index)" : HalloweenCharacter.allCases[index - 13].rawValue
                (title as NSString).draw(at: NSPoint(x: 10, y: y + 4), withAttributes: attributes)
                for (col, icon) in row.enumerated() {
                    let x = CGFloat(140 + col * 48)
                    // Draw raw template pixels to review the actual transparent bitmap on light backgrounds.
                    let display = NSImage(size: icon.size)
                    display.addRepresentation(icon.representations.last!)
                    display.draw(in: NSRect(x: x, y: y, width: 28, height: 28), from: .zero,
                        operation: .sourceOver, fraction: 1)
                }
            }
            for (index, label) in ["REST — 6 frames", "ACTIVE — 6 frames", "BUSY — 6 frames"].enumerated() {
                (label as NSString).draw(at: NSPoint(x: 140 + index * 288, y: height - 22), withAttributes: attributes)
            }
            NSGraphicsContext.restoreGraphicsState()
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        }
        print("CharacterArtworkTests: PASS (8 individual v2 assets; 23 characters, bicycle 8-pose cycles, 1x/2x; distinct pose cycles, face details and squid attachment; edges through rest-to-active/busy; fixed bicycle body; live transitions and stop/resume)")
    }
}
