/******** Book Rigger 3.5 — lightweight Gumroad licensing ********/
global BR_Licensing

struct BR_LicenseStruct
(
    productID   = "vdXfu1oUygT0VVWlVOMxGA==",    -- set this
    verifyURL   = "https://api.gumroad.com/v2/licenses/verify",
	licPath = (getDir #userScripts + "\\book_rigger_license.json"),
    maxAgeDays  = 3,     -- run offline for up to this many days
    graceDays   = 3,    -- if checks fail or offline, keep working within grace
    LicensedEmail = "",
	TmpKey = undefined,   -- temp storage for activation dialog

    /* helpers */
	fn ensureDotNetReady =
	(
		-- TLS 1.2 (already fine in your file)
		try (
			local SPM = dotNetClass "System.Net.ServicePointManager"
			try ( SPM.SecurityProtocol = (dotNetClass "System.Net.SecurityProtocolType").Tls12 )
			catch ( SPM.SecurityProtocol = 3072 )
		) catch()

		-- Try both JSON libs; either is fine
		try ( (dotNetClass "System.Reflection.Assembly").Load "System.Web.Extensions" ) catch()
		try ( (dotNetClass "System.Reflection.Assembly").Load "Newtonsoft.Json" ) catch()
	),

fn httpPost url formData =
(
    ensureDotNetReady()
    try ( (dotNetClass "System.Net.ServicePointManager").Expect100Continue = false ) catch()

    local WebRequest = dotNetClass "System.Net.WebRequest"
    local req        = WebRequest.Create url
    req.Method       = "POST"
    req.ContentType  = "application/x-www-form-urlencoded"
    req.SendChunked  = true  -- no ContentLength needed
    try ( req.Timeout = 15000 ; req.ReadWriteTimeout = 15000 ) catch()
    try ( req.Proxy = WebRequest.DefaultWebProxy
          if req.Proxy != undefined and req.Proxy != null do
              req.Proxy.Credentials = (dotNetClass "System.Net.CredentialCache").DefaultNetworkCredentials
    ) catch()

    local result = undefined

    -- Write the form data as UTF-8 text
    try (
        local enc = dotNetClass "System.Text.Encoding"
        local sw  = dotNetObject "System.IO.StreamWriter" (req.GetRequestStream()) enc.UTF8
        sw.Write formData
        sw.Flush()
        sw.Close()

        local resp = req.GetResponse()
        local sr   = dotNetObject "System.IO.StreamReader" (resp.GetResponseStream()) enc.UTF8
        result = sr.ReadToEnd()
        sr.Close(); resp.Close()
    )
    catch
    (
        local ex = getCurrentException()

        -- Try to read error response body (e.g., invalid key JSON from Gumroad)
        try (
            local resp = ex.Response
            if resp != undefined and resp != null do
            (
                local enc = dotNetClass "System.Text.Encoding"
                local sr  = dotNetObject "System.IO.StreamReader" (resp.GetResponseStream()) enc.UTF8
                result = sr.ReadToEnd()
                sr.Close(); resp.Close()
            )
        ) catch()

        -- Print diagnostics to the listener
        try ( format "httpPost error: % (%)\n" ex.Message ex.GetType().ToString() ) catch()

        if result == undefined do result = "{\"success\":false,\"message\":\"NETWORK_ERROR\"}"
    )

    result
),



	fn parseJSON s =
	(
		/* Dependency-free extractor for the fields we need:
		   success (bool), message (string), purchase.email (string),
		   purchase.refunded (bool), purchase.disputed (bool)
		*/
		local ht = dotNetObject "System.Collections.Hashtable"
		if s == undefined or s == "" do ( ht.Add "success" false ; return ht )

		local sLower = toLower s
		-- success
		ht.Add "success" (findString sLower "\"success\":true" != undefined)

		-- optional message
		local mPos = findString s "\"message\":"
		if mPos != undefined do
		(
			-- find first quote after "message":
			local afterMsg = substring s (mPos + 10) (s.count - (mPos + 10) + 1) -- slice from just after "message":
			local p = findString afterMsg "\""
			if p != undefined do
			(
				local rest = substring afterMsg (p+1) (afterMsg.count - p)
				local q = findString rest "\""
				if q != undefined do ht.Add "message" (substring rest 1 (q-1))
			)
		)

		-- helper: find value for "key":"value" without 3rd arg to findString
		fn extractString j key =
		(
			local k = "\""+key+"\":\""
			local p1 = findString j k
			if p1 == undefined then undefined
			else
			(
				local start = p1 + k.count
				local tail  = substring j start (j.count - start + 1)
				local p2rel = findString tail "\""
				if p2rel == undefined then undefined else ( substring j start (p2rel-1) )
			)
		)

		-- helper: find boolean "key":true/false
		fn extractBool j key =
		(
			local k = "\""+key+"\":"
			local p1 = findString j k
			if p1 == undefined then undefined
			else
			(
				local start = p1 + k.count
				local tail  = substring j start (j.count - start + 1)
				local tailLower = toLower tail
				case of
				(
					((tailLower.count >= 4) and (substring tailLower 1 4 == "true")):  true
					((tailLower.count >= 5) and (substring tailLower 1 5 == "false")): false
					default: undefined
				)
			)
		)

		-- purchase.* (we only need a few fields)
		local email = extractString s "email"
		if email != undefined do
		(
			local pur = dotNetObject "System.Collections.Hashtable"
			pur.Add "email" email

			local refunded = extractBool s "refunded"
			if refunded != undefined do pur.Add "refunded" refunded

			local disputed = extractBool s "disputed"
			if disputed != undefined do pur.Add "disputed" disputed

			ht.Add "purchase" pur
		)

		ht
	),



    fn nowISO = ( (dotNetClass "System.DateTime").UtcNow.ToString "o" ),

    fn readAllText path =
    (
        local s = ""
        if doesFileExist path then
        (
            local f = openFile path
            while not eof f do s += (readLine f) + "\n"
            close f
        )
        s
    ),

	fn saveLicense key email =
	(
		local f = createFile licPath
		local ts = (nowISO() as string) -- make sure it's a MAXScript string
		local js = "{ \"license_key\":\"" + key + "\", \"email\":\"" + email + "\", \"last_check\":\"" + ts + "\" }"
		format "%\n" js to:f
		close f
		LicensedEmail = email
		true
	),

	fn loadStoredLicense =
	(
		local txt = readAllText licPath
		if txt == "" then undefined else
		(
			-- tiny string extractor for "key":"value"
			fn getVal s k =
			(
				local marker = "\"" + k + "\":\""
				local p = findString s marker
				if p == undefined then undefined else
				(
					local start = p + marker.count
					local tail  = substring s start (s.count - start + 1)
					local q     = findString tail "\""
					if q == undefined then undefined else (substring s start (q-1))
				)
			)

			local ht    = dotNetObject "System.Collections.Hashtable"
			local lkey  = getVal txt "license_key"
			local email = getVal txt "email"
			local last  = getVal txt "last_check"

			if lkey  != undefined do ht.Add "license_key" lkey
			if email != undefined do ht.Add "email"       email
			if last  != undefined do ht.Add "last_check"  last
			ht
		)
	),


	fn verify key incrementVal =
	(
		local inc = if incrementVal then "true" else "false"
		local payload = "product_id=" + productID + "&license_key=" + key + "&increment_uses_count=" + inc

		local raw = httpPost verifyURL payload
		format "-- verify raw: %\n" raw

		if raw == undefined or raw == "" then
		(
			-- Build a tiny hashtable so caller never gets undefined
			local ht = dotNetObject "System.Collections.Hashtable"
			ht.Add "success" false
			ht.Add "message" "Could not contact the licensing server."
			ht
		)
		else
			parseJSON raw
	),


	fn showActivateDialog =
	(
		BR_Licensing.TmpKey = undefined

		rollout BR_Activate "Activate Book Rigger"
		(
			group "Enter your Gumroad license key"
			(
				editText edKey "" width:320
			)
			button btOK "Activate" width:150 across:2
			button btCancel "Cancel" width:150 

			on btOK pressed do
			(
				BR_Licensing.TmpKey = edKey.text
				destroydialog BR_Activate
			)
			on btCancel pressed do
			(
				BR_Licensing.TmpKey = undefined
				destroydialog BR_Activate
			)
		)

		createDialog BR_Activate 360 100 modal:true
		BR_Licensing.TmpKey
	),

	fn firstRunActivate =
	(
		local key = showActivateDialog()
		if key == undefined or key == "" do return false

		local resp = verify key true
		if resp == undefined then
		(
			messageBox "Could not contact the licensing server. Please try again."
			false
		)
		else
		(
			local ok = false
			-- Read 'success' safely, even if parsing changed
			try ( ok = (resp.Item["success"] == true) ) catch ( ok = false )

			if ok then
			(
				local pur = undefined
				try ( pur = resp.Item["purchase"] ) catch()
				local email = undefined
				try ( email = pur.Item["email"] ) catch()
				if email == undefined do email = ""

				saveLicense key email
				true
			)
			else
			(
				-- Graceful user message on invalid key
				local msg = undefined
				try ( msg = resp.Item["message"] ) catch()
				if msg == undefined do msg = "Activation failed. Please check your license key and try again."
				if (toUpper msg) == "NETWORK_ERROR" do msg = "Network error or wrong license key. Please try again."
				messageBox msg
				false
			)
		)
	),

	fn needsRefresh lastISO =
	(
		if lastISO == undefined then true
		else
		(
			local last = (dotNetClass "System.DateTime").Parse lastISO
			((dotNetClass "System.DateTime").UtcNow.Subtract last).Days > maxAgeDays
		)
	),

	fn withinGrace lastISO =
	(
		if lastISO == undefined then true
		else
		(
			local last = (dotNetClass "System.DateTime").Parse lastISO
			((dotNetClass "System.DateTime").UtcNow.Subtract last).Days < (maxAgeDays + graceDays)
		)
	),

    /* main gate */
    fn ensureActivated =
    (
        if not doesFileExist licPath then
        (
            return firstRunActivate()
        )
        else
        (
            local lic = loadStoredLicense()
			if lic == undefined then
			(
				return firstRunActivate()
			)
			else
			(
				local key   = lic.Item["license_key"]
				local email = lic.Item["email"]
				local last  = lic.Item["last_check"]

				if email != undefined do LicensedEmail = email

				-- If file is corrupt or missing key, force re-activation
				if key == undefined then
				(
					try(deleteFile licPath)catch()
					return firstRunActivate()
				)

				if needsRefresh last then
				(
					try
					(
						local resp = verify key false
						if resp.Item["success"] == true then
						(
							saveLicense key resp.Item["purchase"].Item["email"]
							true
						)
						else
						(
							if withinGrace last then true else
							(
								deleteFile licPath
								messageBox "License check failed. Please activate again."
								false
							)
						)
					)
					catch
					(
						if withinGrace last then true else
						(
							messageBox "Cannot reach licensing server and grace period ended."
							false
						)
					)
				)
				else true
			)

        )
    )
)

BR_Licensing = BR_LicenseStruct()
/******** end licensing ********/


(
global pRigv3
local page_list_array=#()
local MasCtrl
	
fn pageRig page_count=

(
local temp_plate
animate off

kacSayfa=page_count
	
page_list_array=#()
temp_plate = plane length:68 width:48 lengthsegs:10 widthsegs:50 name:"Temp_Page"
move temp_plate [(24),0,0]
temp_plate.pivot = [0,0,0]

aging=noiseModifier name:"Age"	fractal:true
edging=noiseModifier name:"Edge" fractal:true
addmodifier temp_plate edging
addmodifier temp_plate aging
flexer_a=bend bendaxis:0 fromTo:on bendTo:54 bendfrom:0 name:"BR_Flexer"
flexer_a.center=[0,0,0]
turner=bend bendaxis:0 fromTo:on bendTo:3 bendfrom:0
turner.center=[-(48/2+0),0,0]
turner.gizmo.rotation=(eulerangles 0 0 0) -- Rotation for compansation
lander=bend bendaxis:0 fromTo:on bendTo:10 bendFrom:0
lander.center=[0,0,0]

resettransform temp_plate
/*
turner.gizmo.position
*/
   --with animate on
    (
		--assignControllers
		--turner.gizmo.position.controller = bezier_float()
		turner.BendTo.controller = bezier_float()
		flexer_a.bendangle.controller = bezier_float()
		turner.bendangle.controller = bezier_float()
		lander.bendangle.controller = bezier_float()
		turner.gizmo.position.x_position.controller = bezier_float()
		turner.gizmo.position.y_position.controller = bezier_float()
		turner.gizmo.position.z_position.controller = bezier_float()
		--at time 0
		addnewKey turner.gizmo.position.x_position.controller 0
		addnewKey turner.gizmo.position.y_position.controller 0
		addnewKey turner.gizmo.position.z_position.controller 0
		
		addnewKey turner.gizmo.rotation.z_rotation.controller 0

		addnewKey turner.BendTo.controller 0
		addnewKey flexer_a.bendangle.controller 0
		addnewKey turner.bendangle.controller 0
		addnewKey lander.bendangle.controller 0
		--at time 2
		addnewKey turner.bendangle.controller 2
		--at time 7
		addnewKey turner.BendTo.controller 7
		addnewKey flexer_a.bendangle.controller 7
		addnewKey turner.gizmo.rotation.z_rotation.controller 7
		
		--at time 8
		addnewKey turner.gizmo.position.controller 8
		--at time 10
		addnewKey lander.bendangle.controller 10
		--at time 12
		addnewKey flexer_a.bendangle.controller 12
		addnewKey turner.bendangle.controller 12
		--at time 14
		addnewKey flexer_a.bendangle.controller 14
		addnewKey turner.gizmo.position.controller 14
		addnewKey lander.bendangle.controller 14
		addnewKey turner.BendTo.controller 14
		
		tangentType=#auto
		---------------------------------------------------------
				turner.gizmo.position.x_position.controller.keys[1].value=0
				turner.gizmo.position.y_position.controller.keys[1].value=0
				turner.gizmo.position.z_position.controller.keys[1].value=0
				turner.gizmo.position.x_position.controller.keys[1].intangenttype = tangentType
				turner.gizmo.position.y_position.controller.keys[1].intangenttype = tangentType
				turner.gizmo.position.z_position.controller.keys[1].intangenttype = tangentType
				turner.gizmo.position.x_position.controller.keys[1].outtangenttype = tangentType
				turner.gizmo.position.y_position.controller.keys[1].outtangenttype = tangentType
				turner.gizmo.position.z_position.controller.keys[1].outtangenttype = tangentType
				turner.gizmo.position.x_position.controller.keys[2].value=0
				turner.gizmo.position.y_position.controller.keys[2].value=0
				turner.gizmo.position.z_position.controller.keys[2].value=0
				turner.gizmo.position.x_position.controller.keys[2].intangenttype = tangentType
				turner.gizmo.position.y_position.controller.keys[2].intangenttype = tangentType
				turner.gizmo.position.z_position.controller.keys[2].intangenttype = tangentType
				turner.gizmo.position.x_position.controller.keys[2].outtangenttype = tangentType
				turner.gizmo.position.y_position.controller.keys[2].outtangenttype = tangentType
				turner.gizmo.position.z_position.controller.keys[2].outtangenttype = tangentType
				turner.gizmo.position.x_position.controller.keys[3].value=0
				turner.gizmo.position.y_position.controller.keys[3].value=0
				turner.gizmo.position.z_position.controller.keys[3].value=0
				turner.gizmo.position.x_position.controller.keys[3].intangenttype = tangentType
				turner.gizmo.position.y_position.controller.keys[3].intangenttype = tangentType
				turner.gizmo.position.z_position.controller.keys[3].intangenttype = tangentType
				turner.gizmo.position.x_position.controller.keys[3].outtangenttype = tangentType
				turner.gizmo.position.y_position.controller.keys[3].outtangenttype = tangentType
				turner.gizmo.position.z_position.controller.keys[3].outtangenttype = tangentType
				
				turner.BendTo.controller.keys[1].value=3
				turner.BendTo.controller.keys[1].intangenttype = tangentType
				turner.BendTo.controller.keys[1].outtangenttype = tangentType
				turner.BendTo.controller.keys[2].value=25
				turner.BendTo.controller.keys[2].intangenttype = tangentType
				turner.BendTo.controller.keys[2].outtangenttype = tangentType
				turner.BendTo.controller.keys[3].value=3
				turner.BendTo.controller.keys[3].intangenttype = tangentType
				turner.BendTo.controller.keys[3].outtangenttype = tangentType
				
				turner.bendangle.controller.keys[1].value=0
				turner.bendangle.controller.keys[1].intangenttype = tangentType
				turner.bendangle.controller.keys[1].outtangenttype = tangentType
				turner.bendangle.controller.keys[2].value=0
				turner.bendangle.controller.keys[2].intangenttype = tangentType
				turner.bendangle.controller.keys[2].outtangenttype = tangentType
				turner.bendangle.controller.keys[3].value=-185
				turner.bendangle.controller.keys[3].intangenttype = tangentType
				turner.bendangle.controller.keys[3].outtangenttype = tangentType
				
				flexer_a.bendangle.controller.keys[1].value=0
				flexer_a.bendangle.controller.keys[1].intangenttype = tangentType
				flexer_a.bendangle.controller.keys[1].outtangenttype = tangentType
				flexer_a.bendangle.controller.keys[2].value=-190
				flexer_a.bendangle.controller.keys[2].intangenttype = tangentType
				flexer_a.bendangle.controller.keys[2].outtangenttype = tangentType
				flexer_a.bendangle.controller.keys[3].value=(190)-(((190)/100)*25)
				flexer_a.bendangle.controller.keys[3].intangenttype = tangentType
				flexer_a.bendangle.controller.keys[3].outtangenttype = tangentType
				flexer_a.bendangle.controller.keys[4].value=0
				flexer_a.bendangle.controller.keys[4].intangenttype = tangentType
				flexer_a.bendangle.controller.keys[4].outtangenttype = tangentType
				
				lander.bendangle.controller.keys[1].value=0
				lander.bendangle.controller.keys[1].intangenttype = tangentType
				lander.bendangle.controller.keys[1].outtangenttype = tangentType
				lander.bendangle.controller.keys[2].value=0
				lander.bendangle.controller.keys[2].intangenttype = tangentType
				lander.bendangle.controller.keys[2].outtangenttype = tangentType
				lander.bendangle.controller.keys[3].value=5
				lander.bendangle.controller.keys[3].intangenttype = tangentType
				lander.bendangle.controller.keys[3].outtangenttype = tangentType
    )

MasCtrl = dummy pos:[0,0,0] boxsize:[24,24,24]
MasCtrl.name = uniquename "BookRigger_Book"
----duplicate planes-----
progressstart "Preparing Book Pages..."
seed 12345
for i = 1 to kacSayfa do
(

	t = copy temp_plate
	t.name = uniquename "BookRigger_Page"
	------
	--V4.0 change
	t.modifiers["Edge"].seed=i
	---------------
	t.parent = MasCtrl
	t.pos=[0,0,-((i as float)*(0.2/10))]
	addmodifier t (copy flexer_a)
	t.modifiers[1].name="Flexer"
	addmodifier t (copy lander)
	t.modifiers[1].name="Lander"
	addmodifier t (copy turner)
	t.modifiers[1].name="Turner"

	--V4.0 change
	seed = 12345
	t.modifiers["Flexer"].gizmo.rotation = eulerangles 0 0 (random -25 25) --FLEXER modifier

--t.pivot = [0,((i as float)/100),0]
t.pivot = [0,0,0]


				--addnewKey t.modifiers["Turner"].bendTo.controller 0
--arasayfa=((kacSayfa-(i as float))+(i as float))*0.5+48
t.modifiers["Turner"].bendTo.controller.keys[1].value=3.0+((kacSayfa-(i as float))*(((0.2/10)*5)))
t.modifiers["Turner"].bendTo.controller.keys[2].value=48
t.modifiers["Turner"].bendTo.controller.keys[3].value=3.0+((i as float)*(((0.2/10)*5)))
--t.modifiers["Turner"].bendTo+=((i as float)*(((0.2/10)*5))) --TURNER modifier

			--bendtoKeys[1].value=newVal+((PageArray.count-(i as float))*(((($.PageGap)/10)*5)))
			--bendtoKeys[3].value=newVal+((i as float)*(((($.PageGap)/10)*5)))
			--bendtoKeys[2].value=$.pageWidth
			

--	movekeys t ((i*14)-14)
	append page_list_array t
	progressupdate (100.0 * i / kacsayfa)
)
delete temp_plate
progressend ()


ca=attributes FlipControl
(
	------------------------------------CA MATERIAL FUNCTIONS-------------------------------------
	--Material Function for double sided material

fn image_fromIFL Mat numb = 
(
local selected_txt
IFL_file=openFile $.mat_Diftxt.filename --Loads the IFL file
if $.mat_alphaSource == undefined then (AlphaSource = 2) else (AlphaSource = $.mat_alphaSource-1.0)

--Each readline command reads the next line for the loaded ifl
--Run the command until it reaches the desired line
	if $.mat_seqOrder != true then
	(zivir = (numb*2)-1)
	else
	(zivir = numb)
	
	if zivir > $.mat_Diftxt.numframes then zivir = $.mat_Diftxt.numframes
	for i = 1 to zivir do 
		(
		Selected_txt=readLine IFL_file 
		)
		case of
		(
		(classof Mat.material1==standardmaterial):
			(
			Mat.material1.diffuseMap=bitmaptexture()
			Mat.material1.diffuseMap.filename=((getFilenamePath $.mat_Diftxt.filename) as string)+(selected_txt as string)
			Mat.material1.diffuseMap.alphaSource=AlphaSource
			if $.mat_showTX == true then (showtexturemap Mat Mat.material1.diffusemap on)
			)
		(classof Mat.material1==Arch___Design__mi):
			(
			Mat.material1.diff_color_map=bitmaptexture()
			Mat.material1.diff_color_map.filename=((getFilenamePath $.mat_Diftxt.filename) as string)+(selected_txt as string)
			Mat.material1.diff_color_map.alphasource=AlphaSource
			if $.mat_showTX == true then (showtexturemap Mat Mat.material1.diff_color_map on)
			)
		(classof Mat.material1==VRayMtl):
			(
			Mat.material1.texmap_diffuse=bitmaptexture()
			Mat.material1.texmap_diffuse.filename=((getFilenamePath $.mat_Diftxt.filename) as string)+(selected_txt as string)
			Mat.material1.texmap_diffuse.alphasource=AlphaSource
			if $.mat_showTX == true then (showtexturemap Mat Mat.material1.texmap_diffuse on)
			)
		)
		if $.mat_seqOrder != true then
		(
				if zivir != $.mat_Diftxt.numframes then
				(Selected_txt=readLine IFL_file)
						case of
					(
					(classof Mat.material2==standardmaterial):
						(
						Mat.material2.diffuseMap=bitmaptexture()
						Mat.material2.diffuseMap.filename=((getFilenamePath $.mat_Diftxt.filename) as string)+(selected_txt as string)
						Mat.material2.diffuseMap.coords.U_Tiling=-1
						Mat.material2.diffuseMap.alphaSource=AlphaSource
					if $.mat_showTX == true then (showtexturemap Mat Mat.material2.diffusemap on)
						)
					(classof Mat.material2==Arch___Design__mi):
						(
						Mat.material2.diff_color_map=bitmaptexture()
						Mat.material2.diff_color_map.filename=((getFilenamePath $.mat_Diftxt.filename) as string)+(selected_txt as string)
						Mat.material2.diff_color_map.coords.U_Tiling=-1
						Mat.material2.diff_color_map.alphasource=AlphaSource
						if $.mat_showTX == true then (showtexturemap Mat Mat.material2.diff_color_map on)
						)
					(classof Mat.material2==VRayMtl):
						(
						Mat.material2.texmap_diffuse=bitmaptexture()
						Mat.material2.texmap_diffuse.filename=((getFilenamePath $.mat_Diftxt.filename) as string)+(selected_txt as string)
						Mat.material2.texmap_diffuse.coords.U_Tiling=-1
						Mat.material2.texmap_diffuse.alphasource=AlphaSource
						if $.mat_showTX == true then (showtexturemap Mat Mat.material2.texmap_diffuse on)
						)
					)
		)
)
--End of Material Function

--Material Function for single sided material

fn image_fromIFL2 Mat numb = 
(
local selected_txt
	
if $.mat_alphaSource == undefined then (AlphaSource = 2) else (AlphaSource = $.mat_alphaSource-1.0)
IFL_file=openFile $.mat_Diftxt.filename --Loads the IFL file


--Each readline command reads the next line for the loaded ifl
--Run the command until it reaches the desired line
	if numb > $.mat_Diftxt.numframes then numb = $.mat_Diftxt.numframes
	for i = 1 to numb do 
		(
		Selected_txt=readLine IFL_file 
		)
		case of
	(
	(classof mat==standardmaterial):
		(
		mat.diffuseMap=bitmaptexture()
		Mat.diffuseMap.filename=((getFilenamePath $.mat_Diftxt.filename) as string)+(selected_txt as string)
		Mat.diffuseMap.alphaSource=AlphaSource
		if $.mat_showTX == true then (showtexturemap Mat Mat.diffusemap on)
		)
	(classof mat==Arch___Design__mi):
		(
		mat.diff_color_map=bitmaptexture()
		Mat.diff_color_map.filename=((getFilenamePath $.mat_Diftxt.filename) as string)+(selected_txt as string)
		Mat.diff_color_map.alphasource=AlphaSource
		if $.mat_showTX == true then (showtexturemap Mat Mat.diff_color_map on)
		)
	(classof mat==VRayMtl):
		(
		mat.texmap_diffuse=bitmaptexture()
		Mat.texmap_diffuse.filename=((getFilenamePath $.mat_Diftxt.filename) as string)+(selected_txt as string)
		Mat.texmap_diffuse.alphasource=AlphaSource
		if $.mat_showTX == true then (showtexturemap Mat Mat.texmap_diffuse on)
		)
	)
)

--End of singlesided Material Function

fn AssignMaterials =
(

if $.mat_dblsided == true then 
	(
		double_mat=doublesided()
	)  -- Double Sided Material

PageArray=$BookRigger_Page* as array
progressStart "Changing Materials"
for i = 1 to PageArray.count where PageArray[i].parent == $ do
(

		--MATERIAL
	if $.mat_dblsided == false then
	(
		if $.mat_frontMaterial != undefined then
		(
		PageArray[i].material = copy $.mat_frontMaterial
			if $.mat_Diftxt != undefined then
			(
			image_fromIFL2 PageArray[i].material i
			)
		)
	)
	
		if $.mat_dblsided == true then
	(
		if $.mat_frontMaterial !=undefined and $.mat_backMaterial != undefined then
		(
			PageArray[i].material = copy double_mat
			PageArray[i].material.material1=copy $.mat_frontMaterial
			PageArray[i].material.material2=copy $.mat_backMaterial
			if $.mat_Diftxt != undefined then
			(
			image_fromIFL PageArray[i].material i
				------------------------------------------------------------------

			)
		)
	)
	progressUpdate (100 * i / PageArray.count)
)
progressEnd ()
)

--Functions for Show in Viewport
fn offShowInViewport Mat obj state=
(
		--if state==true then state=on else off
		if (numSubMtls = getNumSubMtls Mat) != 0 then
			for i = 1 to numSubMtls do
				offShowInViewport (getSubMtl Mat i) obj state
		else
		(
		
			--------------------------------------------
			case of
				(
				(classof mat==standardmaterial):showtexturemap obj.material Mat.diffusemap state
					
				(classof mat==Arch___Design__mi):showtexturemap obj.material Mat.diff_color_map state
					
				(classof mat==VRayMtl):showtexturemap obj.material Mat.texmap_diffuse state
					
				)
			--------------------------------------------

		)

)

fn  showTXT state =
(
PageArray=$BookRigger_Page* as array
for x in PageArray where x.parent == $ do
(
(
	if x.material != undefined then (offShowInViewport x.material x state)
	
	)
)
)

---------------------------------------------------
------------------------------END OF CA MATERIAL FUNCTIONS----------------------------------


	fn pageWidthChange widthVal =
	(
		with animate off
		(
		pageRot=eulerangles 0 -$.BottomAngle 0
		PageMatrix=pageRot as matrix3
		ParentMatrix=$.transform
		RotMatrix=PageMatrix*ParentMatrix
	PageArray=$BookRigger_Page* as array
		for i in PageArray where i.parent == $ do
		(
		currentWidth=i.width
		i.width=widthVal
		differenceWidth = widthVal-currentWidth
		in coordsys RotMatrix move i [(differenceWidth/2),0,0]
		turnerM=i.modifiers["Turner"]
		landerM=i.modifiers["Lander"]
		turnerM.center=[-(widthVal/2+$.Turn_CCenter),0,0]
		turnerM.gizmo.position=[(-((widthVal/2) - (cos( ($.Turn_CCenter))*(widthVal/2)))),0,(((abs(sin( ($.Turn_CCenter)))) * (widthVal/2)) + ((abs(sin(radToDeg (0)))) * (widthVal/2)))] --Transform fix of the not-pivot-oriented rotation
		--landerM.center=[(-widthVal)+$.Land_CCenter,0,0]
		i.modifiers["Turner"].BendTo.controller[1].keys[2].value=widthVal
			i.pivot=$.pivot
		)
		)
	)
	fn pageLengthChange lengthVal = 
	(
		PageArray=$BookRigger_Page* as array
		for i in PageArray where i.parent == $ do
		(i.length=lengthVal)
	)
	fn gapChange gapVal=
	(
		with animate off
		(
		pageRot=eulerangles 0 -$.BottomAngle 0
		PageMatrix=pageRot as matrix3
		ParentMatrix=$.transform
		RotMatrix=PageMatrix*ParentMatrix
		PageArray=for a in $BookRigger_Page* where a.parent==$ collect a
		
		for i =1 to PageArray.count do
		(
		in coordsys RotMatrix PageArray[i].pos.z= (-((i as float)*(((gapVal-$.pageGapInit))/10)))
			bendtoKeys=pageArray[i].modifiers["Turner"].BendTo.controller[1].keys
			bendtoKeys[3].value=$.Turn_CArea+((i as float)*((((gapVal)/10)*5)))
			bendtoKeys[1].value=$.Turn_CArea+((PageArray.count-(i as float))*((((gapVal)/10)*5)))
		--pageArray[i].pivot=$.pivot
		)
		)
	)
	fn gapChangePivotFix=
	(
		with animate off
		(
		PageArray=for a in $BookRigger_Page* where a.parent==$ collect a
			for i in PageArray do
			(
				i.pivot=PageArray[1].pivot
				$.PageGapInit=$.PageGap
			)
		)
	)
	fn Flex_MaxAngleChange newVal =
	(
		with animate off
		(
		PageArray=$BookRigger_Page* as array
		for i in PageArray where i.parent == $ do
		(
			MaxAngleKeys=i.modifiers["Flexer"].angle.controller[1].keys
			MaxAngleKeys[2].value=-newVal
			MaxAngleKeys[3].value=(newVal)-(((newVal)/100)*25)
		)
		)
	)
	fn Flex_RandomGizmoChange =
	(
		with animate off
		(
		seed $.Flex_RandomSeed
		PageArray=$BookRigger_Page* as array
		for i in PageArray where i.parent == $ do
		(
			if $.Flex_Random == true then
			(
				--seed (random )
				i.modifiers["Flexer"].gizmo.rotation = eulerangles 0 0 (random -$.Flex_RandomDegree $.Flex_RandomDegree)
			)
			else
			(
				i.modifiers["Flexer"].gizmo.rotation = eulerangles 0 0 ($.Flex_RandomDegree)
			)
		)
		)
	)
	fn Turn_CAreaChange newVal =
	(
		with animate off
		(
		PageArray=$BookRigger_Page* as array
		for i = 1 to PageArray.count where PageArray[i].parent == $ do
		(
		--PageArray[i].modifiers["Turner"].bendTo.controller[3].value=((i as float)*(($.PageGap-0.2)/10)*5)+(newVal-3.0)
			bendtoKeys=pageArray[i].modifiers["Turner"].BendTo.controller[1].keys
			bendtoKeys[3].value=newVal+((i as float)*(((($.PageGap)/10)*5)))
			--bendtoKeys[2].value=$.pageWidth
			bendtoKeys[1].value=newVal+((PageArray.count-(i as float))*(((($.PageGap)/10)*5)))
		)
		)
	)
	fn Turn_maxAngleChange newValue =
	(
		with animate off
		(
		PageArray=$BookRigger_Page* as array
		for i in PageArray where i.parent == $ do
		(
			MaxAngleKeys=i.modifiers["Turner"].BendAngle.controller[1].keys
			MaxAngleKeys[3].value=-newValue
		)
		)
	)
	fn Turn_minAngleChange newValue=
	(
		with animate off
		(
		PageArray=$BookRigger_Page* as array
		for i in PageArray where i.parent == $ do
		(
			MinAngleKeys=i.modifiers["Turner"].BendAngle.controller[1].keys
			MinAngleKeys[1].value=newValue
		)
		)
	)
	fn Turn_CLevelChange newVal =
	(
		with animate off
		(
	PageArray=$BookRigger_Page* as array
		for i in PageArray where i.parent == $ do
		(
		turnerM=i.modifiers["Turner"]
		turnerM.gizmo.rotation=(eulerangles 0 newVal 0) -- Rotation for compansation
		turnerM.gizmo.position=[(-(($.pageWidth/2) - (cos( (newVal))*($.pageWidth/2)))),0,(((abs(sin( (newVal)))) * ($.pageWidth/2)) + ((abs(sin(radToDeg (0)))) * ($.pageWidth/2)))] --Transform fix of the not-pivot-oriented rotation
		)
		)
	)

	fn Land_MaxAngleChange newVal =
	(
		with animate off
		(
		PageArray=$BookRigger_Page* as array
		for i in PageArray where i.parent == $ do
		(
			MaxAngleKeys=i.modifiers["Lander"].BendAngle.controller[1].keys
			MaxAngleKeys[3].value=newVal
		)
		)
	)
	fn Land_MinAngleChange newVal = 
	(
		with animate off
		(
		PageArray=$BookRigger_Page* as array
		for i in PageArray where i.parent == $ do
		(
			MaxAngleKeys=i.modifiers["Lander"].BendAngle.controller[1].keys
			MaxAngleKeys[1].value=newVal
		)
		)
	)
	fn TakeApartChange =
	(
		with animate off
		(
		seed $.TakeApart_Seed
		PageArray=$BookRigger_Page* as array
		for i = 1 to PageArray.count where PageArray[i].parent == $ do
		(
			if $.enablethorn == true then
			(
					if (random 1 $.apro) == 1 then
				(
				if $.rThornGizmo==true then
					(
						--with animate off
						--PageArray[i].modifiers["Turner"].gizmo.rotation.z_rotation.controller.keys[1].value=0
						PageArray[i].modifiers["Turner"].gizmo.rotation.z_rotation.controller.keys[1].value=0
						PageArray[i].modifiers["Turner"].gizmo.rotation.z_rotation.controller.keys[2].value=(random -$.rdegree $.rdegree )
						)
				else
					(
						--with animate off
						--PageArray[i].modifiers["Turner"].gizmo.rotation.z_rotation.controller.keys[1].value= 0
					PageArray[i].modifiers["Turner"].gizmo.rotation.z_rotation.controller.keys[1].value= $.rdegree
					PageArray[i].modifiers["Turner"].gizmo.rotation.z_rotation.controller.keys[2].value= $.rdegree
						)
				MaxAngleKeys=PageArray[i].modifiers["Turner"].BendAngle.controller[1].keys
				MaxAngleKeys[3].value=-(random $.tstart $.tend)
				GizmoPosKeys=PageArray[i].modifiers["Turner"].gizmo.position.controller.xposition.controller.keys
				--GizmoPosKeys[1].value=0
				GizmoPosKeys[2].value=0
				GizmoPosKeys[3].value=-30
				setafterORT PageArray[i].modifiers["Turner"].gizmo.position.controller #linear
				PageArray[i].modifiers["Turner"].gizmo.position.x_position.keys[3].intangenttype = #linear
				setafterORT PageArray[i].modifiers["Lander"].bendangle.controller #linear
				try
				(PageArray[i].modifiers["Lander"].bendangle.keys[3].outtangenttype = #linear)
				catch()
				)
			)
			else
			(
				--PageArray[i].modifiers["Turner"].gizmo.rotation.z_rotation.controller.keys[1].value= 0
				PageArray[i].modifiers["Turner"].gizmo.rotation.z_rotation.controller.keys[1].value= 0
				PageArray[i].modifiers["Turner"].gizmo.rotation.z_rotation.controller.keys[2].value= 0

				
				MaxAngleKeys=PageArray[i].modifiers["Turner"].BendAngle.controller[1].keys
				MaxAngleKeys[3].value=-($.Turn_MaxAngle)
				GizmoPosKeys=PageArray[i].modifiers["Turner"].gizmo.position.controller.xposition.controller.keys
				GizmoPosKeys[1].value=0
				GizmoPosKeys[2].value=0
				GizmoPosKeys[3].value=0
				setafterORT PageArray[i].modifiers["Turner"].gizmo.position.controller #constant
				PageArray[i].modifiers["Turner"].gizmo.position.x_position.keys[3].intangenttype = #auto
				setafterORT PageArray[i].modifiers["Lander"].bendangle.controller #constant
				try(
				PageArray[i].modifiers["Lander"].bendangle.keys[3].outtangenttype = #auto)
				catch()
			)
		)
		)
	)
	fn TakeApartReset =
	(
		with animate off
		(
		PageArray=$BookRigger_Page* as array
		for i = 1 to PageArray.count where PageArray[i].parent == $ do
			(
				PageArray[i].modifiers["Turner"].gizmo.rotation.z_rotation.controller.keys[1].value= 0
				PageArray[i].modifiers["Turner"].gizmo.rotation.z_rotation.controller.keys[2].value= 0
				
				MaxAngleKeys=PageArray[i].modifiers["Turner"].BendAngle.controller[1].keys
				MaxAngleKeys[3].value=-($.Turn_MaxAngle)
				GizmoPosKeys=PageArray[i].modifiers["Turner"].gizmo.position.controller.xposition.controller.keys
				GizmoPosKeys[1].value=0
				GizmoPosKeys[2].value=0
				GizmoPosKeys[3].value=0
				setafterORT PageArray[i].modifiers["Turner"].gizmo.position.controller #constant
				PageArray[i].modifiers["Turner"].gizmo.position.x_position.keys[3].intangenttype = #auto
				setafterORT PageArray[i].modifiers["Lander"].bendangle.controller #constant
				try(PageArray[i].modifiers["Lander"].bendangle.keys[3].outtangenttype = #auto)catch()
				try(PageArray[i].modifiers["Lander"].bendangle.keys[3].intangenttype=#auto)catch()
			)
		)
	)
	--v4.0 change
	fn ResetToDefaults=
	(
		--PageProperties
		$.FlipControl.pageWidth = 48.0
		pageWidthChange 48.0
		$.FlipControl.pageLength = 68.0
		pageLengthChange 68
		$.FlipControl.pageGap = 0.2
		gapChange 0.2
		gapChangePivotFix()
		$.FlipControl.LengthSegs = 10
		$.FlipControl.WidthSegs = 50
		$.FlipControl.EdgeRandFq = 35.0
		$.FlipControl.EdgeRandVal = 0.3
		$.FlipControl.OldnessFq = 35.0
		$.FlipControl.OldnessVal = 0.0
		
		--Flexibility Properties
		
		$.FlipControl.Flex_CCenter = 0.0
		$.FlipControl.Flex_CArea = 54.0
		$.FlipControl.Flex_MaxAngle = 190.0
		Flex_MaxAngleChange 190.0
		$.FlipControl.Flex_Random = true
 		$.FlipControl.Flex_RandomDegree = 25
		$.FlipControl.Flex_RandomSeed = 12345
		Flex_RandomGizmoChange()
		
		--Turn Properties
		$.FlipControl.Turn_CCenter = 0.0
		$.FlipControl.Turn_CArea = 3.0
		Turn_CAreaChange 3.0
		$.FlipControl.Turn_maxAngle = 185.0
		Turn_maxAngleChange 185.0
		$.FlipControl.Turn_minAngle = 0.0
		Turn_minAngleChange 0.0
 		$.FlipControl.Turn_CLevel = 0.0
		Turn_CLevelChange 0.0

		--Land Properties
		$.FlipControl.Land_CCenter = 0.0
		$.FlipControl.Land_CArea = 10.0
		$.FlipControl.Land_maxAngle = 5.0
		Land_MaxAngleChange 5.0
		$.FlipControl.Land_minAngle = 0.0
		Land_minAngleChange 0.0
		
		--TakeApart
		$.FlipControl.enablethorn = false
		$.FlipControl.apro = 2
		$.FlipControl.rThornGizmo = true
		$.FlipControl.rdegree = 50
		$.FlipControl.tstart = 100
		$.FlipControl.tend = 180
		$.FlipControl.TakeApart_Seed = 12345
		TakeApartChange()
		--aproSP.enabled=false
	)

	----------------------------

    parameters AnimP rollout:AnimR
    (
        Flip type:#float ui:(Flipsp) 
		shuffle type:#float ui:(ShuffleSP)
		multiplier type:#float ui:(multiplierSP) default:1.0
		extraCrease type:#float ui:(extraCreaseSP)
		bottomAngle type:#float ui:(bottomAngleSP)
		extraFlex type:#float ui:(extraFlexSP)
		turnAngle type:#float ui:(turnAngleSP) default:0.0
		flexAngle type:#float ui:(flexAngleSP) default:0.0
		landAngle type:#float ui:(landAngleSP) default:0.0
    )
	parameters PageProP rollout:PageProR
	(
		pageWidth type:#float ui:(pageWidthSP) animatable:false
		pageLength type:#float ui:(pageLengthSP) animatable:false
		pageGap type:#float ui:(pageGapSP) animatable:false
		pageGapInit type:#float default:0.2 animatable:false
		LengthSegs type:#integer ui:(lengthSegsSP) animateable:true
		WidthSegs type:#integer ui:(widthSegsSP) animateable:true
		EdgeRandFq type:#float ui:(edgeRandFqSP) animateable:true
		EdgeRandVal type:#float ui:(edgeRandValSP) animateable:true
		OldnessFq type:#float ui:(oldnessFqSP) animateable:true
		OldnessVal type:#float ui:(oldnessValSP) animateable:true
		--maxAngle type:#float ui:(maxAngleSP)
	)
	parameters MaterialP rollout:MaterialR
	(
		mat_dblsided type:#boolean ui:(mat_dblsidedCB)
		mat_frontMaterial type:#material
		mat_backMaterial type:#material
		mat_seqOrder type:#boolean ui:(mat_seqOrderCB)
		mat_Diftxt type:#bitmap
		mat_undefined type:#bitmap
		mat_alphaSource type:#radiobtnIndex ui:(mat_alphaSourceRB)
		mat_showTX type:#boolean ui:(mat_showTXCB)
	)
	parameters FlexP rollout:FlexR
	(
		Flex_CCenter type:#float ui:(Flex_CCenterSP) animatable:true
		Flex_CArea type:#float ui:(Flex_CAreaSP) animatable:true
		Flex_MaxAngle type:#float ui:(Flex_MaxAngleSP) animatable:false
		Flex_Random type:#boolean ui:(Flex_RandomCB)
 		Flex_RandomDegree type:#float ui:(Flex_RandomDegreeSP) animatable:false
		Flex_RandomSeed type:#integer ui:(Flex_RandomSeedSP) default:12345 animatable:false
	)
	parameters TurnP rollout:TurnR
	(
		Turn_CCenter type:#float ui:(Turn_CCenterSP) animatable:true
		Turn_CArea type:#float ui:(Turn_CAreaSP) animatable:false
		Turn_maxAngle type:#float ui:(Turn_maxAngleSP) animatable:false
		Turn_minAngle type:#float ui:(Turn_minAngleSP) default:0.0 animatable:false
 		Turn_CLevel type:#float ui:(Turn_CLevelSP) animatable:false
		--Turn_BottomAngle type:#float ui:(Turn_BottomAngleSP)
	)
	parameters LandingP rollout:LandingR
	(
		Land_CCenter type:#float ui:(Land_CCenterSP) animatable:true
		Land_CArea type:#float ui:(Land_CAreaSP) animatable:true
		Land_maxAngle type:#float ui:(Land_maxAngleSP) animatable:false
		Land_minAngle type:#float ui:(Land_minAngleSP) animatable:false
	)
	parameters TakeApartP rollout:TakeApartR
	(
		enablethorn type:#boolean ui:(enablethornCB)
		apro type:#integer ui:(aproSP) animatable:false
		rThornGizmo type:#boolean ui:(rThornGizmoCB) animatable:false
		rdegree type:#float ui:(rdegreeSP) animatable:false
		tstart type:#float ui:(tstartSP) animatable:false
		tend type:#float ui:(tendSP) animatable:false
		TakeApart_Seed type:#integer ui:(TakeApart_SeedSP) animatable:false
	)
	parameters AboutP rollout:AboutR
	(
		licensedTo01 type:#string default:"USERNAME"
	)
    rollout AnimR "Animation"
    (
        local fW = 40, oS = [0,-23]
        spinner Flipsp  "Page" type:#float range: [0,9999,0] fieldwidth:fW
		spinner ShuffleSP "Shuffle" type:#float range:[-9999,9999,0] fieldwidth:fW
		spinner multiplierSP "Multiplier" type:#float range:[0,99999,1] fieldwidth:fW
		spinner extraCreaseSP "Crease Correction" type:#float range:[-9999,9999,0] fieldwidth:fW
		spinner bottomAngleSP "Bottom Angle" type:#float range:[-360,360,0] fieldwidth:fW
		spinner extraFlexSP "Flex Angle" type:#float range:[-360,360,0] fieldwidth:fW
		spinner flexAngleSP "Flex Angle Tweak" type:#float range:[-360,360,0] fieldwidth:fW
		spinner turnAngleSP "Turn Angle Tweak" type:#float range:[-360,360,0] fieldwidth:fW
		spinner landAngleSP "Land Angle Tweak" type:#float range:[-360,360,0] fieldwidth:fW
    )
	rollout PageProR "Page Properties"
	(
		local fW = 40, oS = [0,-23]
		spinner pageWidthSP "Page Width" type:#float range:[0,9999,50] fieldwidth:fW
		spinner pageLengthSP "Page Length" type:#float range:[0,9999,48] fieldwidth:fW
		button pageGapBT "Set Page Gap" height:15 across:2
		spinner pageGapSP "" type:#float range:[-999,999,0.0] fieldwidth:fW 
		spinner lengthSegsSP "Length Segs" type:#integer range:[0,9999,10] fieldwidth:fW
		spinner widthSegsSP "Width Segs" type:#integer range:[0,9999,50] height:20 fieldwidth:fW
		--V4.0 Change
		spinner EdgeRandFqSP "Edge Freq." type:#float range:[0,999999,35.0] fieldwidth:fW
		spinner EdgeRandValSP "Edge Random Value" type:#float range:[0,999999,0.5] fieldwidth:fW
		spinner OldnessFqSP "Oldness Freq" type:#float range:[0,999999,0.5] fieldwidth:fW
		spinner OldnessValSP "Oldness Value" type:#float range:[0,999999,0.5] fieldwidth:fW
		---------------------------------------------------------------------------
		
	on pageWidthSP changed val do
	(pageWidthChange pageWidthSP.value)
	on pageLengthSP changed val do
	(pageLengthChange pageLengthSP.value)

		on pageGapBT pressed do
		(
		gapChange pageGapSP.value
		gapChangePivotFix()
		)
	)
	rollout MaterialR "Material"
	(
		local fW = 40, oS = [0,-23]

		checkbox mat_dblsidedCB "Double Sided" pos:[16,10] checked:false
		checkButton mat_frontMatCBut "Front Mat." pos:[16,27] width:60 height:16
		checkButton mat_backMatCBut "Back Mat." pos:[76,27] width:60 height:16 enabled:false
		button mat_DiftxtBut "Select Sequence (Dif)" pos:[16,47] width:120 height:16
		checkBox mat_seqOrderCB "Only Front sides"pos:[16,67] enabled:false
		groupBox mat_grp "Alpha Source" pos:[16,87] width:120 height:62
		radioButtons mat_alphaSourceRB "" pos:[24,103] width:102 height:62 labels:#("Image Alpha", "RGB Intensity", "None (Opaque)") columns:1
		button mat_changeMat "Change Materials" pos:[16,155]
		checkBox mat_showTXCB "Show Texture" pos:[16,188]
		on mat_dblsidedCB changed state do
		(mat_backMatCBut.enabled=mat_dblsided)
		
		on mat_frontMatCBut changed state do
            (
			global backupM
				if state == on and mat_dblsided == false then
				(
				mat_backMatCBut.enabled = false
				)
				if state == off and mat_dblsided == true then
				(
				mat_backMatCBut.enabled =true
				)
                if(state==true) then
                (
					backupM=meditMaterials[1]
                    MatEditor.Open()
                    medit.setactivemtlslot 1 true
                    if(mat_frontMaterial==undefined) then
                        meditMaterials[1]=standardMaterial()
                    else
                        meditMaterials[1]=mat_frontMaterial
                   mat_frontMatCBut.text="Click When Done"   
                   
                )
                else
                (
                    MatEditor.close()
                    if((classof meditMaterials[1]) == standard or (classof meditMaterials[1]) == Arch___Design__mi or (classof meditMaterials[1]) == VRayMtl) then
                    (
                      mat_frontMaterial=meditMaterials[1]
                        mat_frontMatCBut.text=mat_frontMaterial.name + " ( " +((classof mat_frontMaterial) as string) +" )"
						meditMaterials[1]=backupM
                    )
                    else
                    (
                        messagebox "Only Standard, Arch Design (Mental Ray) or Vray Materials!!"
						mat_frontMatCBut.text="Select Front Material"
                    )
                )
            )
			
		on mat_backMatCBut changed state do
            (
				if state == on then
				(mat_frontMatCBut.enabled = false)
				else
				(mat_frontMatCBut.enabled =true)

                if(state==true) then
                (
					backupM=meditMaterials[1]
                    MatEditor.Open()
                    medit.setactivemtlslot 1 true
                    if(mat_backMaterial==undefined) then
                        meditMaterials[1]=standardMaterial()
                    else
                        meditMaterials[1]=mat_backMaterial
                  mat_backMatCBut.text="Click When Done"   
                   
                )
                else
                (
                    MatEditor.close()
                    if((classof meditMaterials[1]) == standard or (classof meditMaterials[1]) == Arch___Design__mi or (classof meditMaterials[1]) == VRayMtl) then
                    (
					mat_backMaterial=meditMaterials[1]
					
					mat_backMatCBut.text=mat_backMaterial.name + " ( " +((classof mat_backMaterial) as string) +" )"
						meditMaterials[1]=backupM
                    )
                    else
                    (
                        messagebox "Only Standard, Arch Design (Mental Ray) or Vray Materials!!"
						mat_backMatCBut.text="Select Front Material"
                    )
                )
            )
			
		on mat_DiftxtBut pressed do
		(
				Temp_mat_Diftxt = selectBitmap ()
				if Temp_mat_Diftxt == undefined or Temp_mat_Diftxt.numframes < 2 then 
				(
					messagebox "please select an image sequence"
					--mat_Diftxt=$.mat_undefined
					--mat_seqOrderCB.enabled=false
				)
				else
				(
					mat_Diftxt=Temp_mat_Diftxt
					mat_DiftxtBut.text = mat_Diftxt.filename
					if mat_dblsidedCB.enabled==true then mat_seqOrderCB.enabled=true
				) 
		)
			
		on mat_DiftxtBut rightclick do
		(
		if keyboard.shiftPressed == true then
		(
		mat_Diftxt = undefined
		mat_DiftxtBut.text="Select Sequence (Diffuse)"
		mat_seqOrderCB.enabled=false
		)
		) 
			 
		on mat_changeMat pressed do
		(AssignMaterials())
			
		on mat_showTXCB changed state do
		(
		showTXT mat_showTXCB.state
		)			

	)--end of  rollout MaterialR
	rollout FlexR "Flexibility Properties"
	(
		local fW = 40
		spinner Flex_CCenterSP "Crease Center" type:#float range:[-99999,99999,0] fieldwidth:fW
		spinner Flex_CAreaSP "Crease Area" type:#float range:[1,99999,54.0] fieldwidth:fW
		spinner Flex_MaxAngleSP "Max Angle" type:#float range:[-360,360,190.0] fieldwidth:fW
		checkbox Flex_RandomCB "Random Curl Direction" width:128 height:16 checked:true
		spinner Flex_RandomDegreeSP "" type:#float range:[-180,180,25.0] fieldwidth:fW across:2
		label ldefdegree "degrees"
		spinner Flex_RandomSeedSP "Seed" type:#integer range:[1,999999,12345] fieldwidth:60

		--on Flex_CCenterSP changed val do
		--(Flex_CCenterChange Flex_CCenterSP.value)
		--on Flex_CAreaSP changed val do
		--(Flex_CAreaChange Flex_CAreaSP.value)
		on Flex_MaxAngleSP changed val do
		(Flex_MaxAngleChange Flex_MaxAngleSP.value)
		on  Flex_RandomCB changed state do
		(Flex_RandomGizmoChange())
		on Flex_RandomDegreeSP changed val do
		(Flex_RandomGizmoChange())
		on Flex_RandomSeedSP changed val do
		(Flex_RandomGizmoChange())
	)
	rollout TurnR "Turn Properties"
	(
	local fW = 40, oS = [0,-23]
	spinner Turn_CCenterSP "Crease Center" type:#float range:[-9999,9999,0] fieldwidth:fW
	spinner Turn_CAreaSP "Crease Area" type:#float range:[-9999,9999,3] fieldwidth:fW
	spinner Turn_maxAngleSP "Max Angle" type:#float range:[-360,360,185] fieldwidth:fW
	spinner Turn_minAngleSP "Min Angle" typr:#float range:[-360,360,0] fieldwidth:fW
	spinner Turn_CLevelSP "Crease Level" type:#float range:[-9999,9999,0] fieldwidth:fW

	on Turn_CAreaSP changed val do
	(Turn_CAreaChange Turn_CAreaSP.value)
	on Turn_maxAngleSP changed val do
	(Turn_maxAngleChange Turn_maxAngleSP.value)
	on Turn_minAngleSP changed val do
	(Turn_minAngleChange Turn_minAngleSP.value)
	on Turn_CLevelSP changed val do
	(Turn_CLevelChange Turn_CLevelSP.value)

	)
	rollout LandingR "Landing Properties"
	(
	local fW = 40, oS = [0,-23]
	spinner Land_CCenterSP "Crease Center" type:#float range:[-9999,9999,0] fieldwidth:fW
	spinner Land_CAreaSP "Crease Area" type:#float range:[0,9999,10] fieldwidth:fW
	spinner Land_maxAngleSP "Max Angle" type:#float range:[-360,360,5] fieldwidth:fW
	spinner Land_minAngleSP "Min Angle" type:#float range:[-360,360,0] fieldwidth: fW
	--on Land_CCenterSP changed val do
	--(Land_CCenterChange Land_CCenterSP.value)
	--on Land_CAreaSP changed val do
	--(Land_CAreaChange Land_CAreaSP.value)
	on Land_maxAngleSP changed val do
	(Land_MaxAngleChange Land_MaxAngleSP.value)
	on Land_minAngleSP changed val do
	(Land_minAngleChange Land_minAngleSP.value)
	)
	rollout TakeApartR "Take Apart"
	(
	checkbox enablethornCB "Enable Taking Pages Apart" checked:false
	spinner aproSP "1/" range:[1,9999,2] fieldwidth:30 type:#integer enabled:false across:2
	label ldef1 " of total pages" enabled:false
	checkbox rThornGizmoCB "Randomize Direction" checked:true enabled:false
	
	spinner rdegreeSP "degrees" range:[-360,360,50] fieldwidth:40 enabled:false	
	label ldef2 "Takes action between" enabled:false
	spinner tstartSP "" range:[0,360,100] fieldwidth:40 enabled:false across:2
	spinner tendSP " - " range:[0,360,180] fieldwidth:40 enabled:false	
	label ldef3 "degrees" align:#right enabled:false
	spinner TakeApart_SeedSP "Seed" type:#integer range:[1,999999,12345] fieldwidth:60

		on enablethornCB changed state do
			(
			if state == true then
				(
				aproSP.enabled=true
				ldef1.enabled=true
				rThornGizmoCB.enabled=true
				rdegreeSP.enabled=true
				ldef2.enabled=true
				takeapartSP=true
				tstartSP.enabled=true
				tendSP.enabled=true
				ldef3.enabled=true
				TakeApartChange()
				)
			else
				(
				aproSP.enabled=false
				ldef1.enabled=false
				rThornGizmoCB.enabled=false
				rdegreeSP.enabled=false
				ldef2.enabled=false
					takeapartSP=false
					tstartSP.enabled=false
					tendSP.enabled=false
					ldef3.enabled=false
				TakeApartChange()
				)
			)
			on aproSP changed val do
			(
				TakeApartReset()
				TakeApartChange()
				)
			on rThornGizmoCB changed state do
			(TakeApartChange())
			on rdegreeSP changed val do
			(TakeApartChange())
			on tstartSP changed val do
			(TakeApartChange())
			on tendSP changed val do
			(TakeApartChange())
			on TakeApart_SeedSP changed val do
			(
				TakeApartReset()
				TakeApartChange()
			)
	)
	--v4.0 change
	rollout ResetR "Reset"
	(
		button resetBut "Reset to defaults"
		on resetBut pressed do
		(
		if querybox "This will reset all properties of the current rig except from Animation and Material rollouts. Are you sure you want to continue?" then
		(ResetToDefaults())
		)
	)
	rollout AboutR "About"
	(
		label licensedTo00L "Licensed To: " --across:2
		label licensedTo01L "USERNAME"
	)
)--End of CA attributes



custAttributes.add MasCtrl ca

		MasCtrl.FlipControl.Flex_CCenter = 0.0
		MasCtrl.FlipControl.Flex_CArea = 54.0
		MasCtrl.FlipControl.Flex_MaxAngle = 190.0
		MasCtrl.FlipControl.Flex_Random = true
 		MasCtrl.FlipControl.Flex_RandomDegree = 25
		MasCtrl.FlipControl.pageWidth = 48.0
		MasCtrl.FlipControl.pageLength = 68.0
		MasCtrl.FlipControl.pageGap = 0.2
		MasCtrl.FlipControl.LengthSegs = 10
		MasCtrl.FlipControl.WidthSegs = 50
		--V4.0 Change
		------------------------------------------------------
		MasCtrl.FlipControl.EdgeRandFq = 35.0
		MasCtrl.FlipControl.EdgeRandVal = 0.3
		MasCtrl.FlipControl.OldnessFq = 35.0
		MasCtrl.FlipControl.OldnessVal = 0.0
		-------------------------------------------------------
		MasCtrl.FlipControl.Turn_CCenter = 0.0
		MasCtrl.FlipControl.Turn_CArea = 3.0
		MasCtrl.FlipControl.Turn_maxAngle = 185.0
 		MasCtrl.FlipControl.Turn_CLevel = 0.0
		MasCtrl.FlipControl.Land_CCenter = 0.0
		MasCtrl.FlipControl.Land_CArea = 10.0
		MasCtrl.FlipControl.Land_maxAngle = 5.0
		MasCtrl.FlipControl.enablethorn = false
		MasCtrl.FlipControl.apro = 2
		MasCtrl.FlipControl.rThornGizmo = true
		MasCtrl.FlipControl.rdegree = 50
		MasCtrl.FlipControl.tstart = 100
		MasCtrl.FlipControl.tend = 180
		MasCtrl.FlipControl.TakeApart_Seed = 12345
		
(
mult_exp = Bezier_Float ()
Flip_exp = Bezier_Float ()
Flip_exp2 = Bezier_Float ()
Flip_exp3 = Bezier_Float ()
Flip_exp4 = Bezier_Float ()
Flip_exp5 = Bezier_Float ()
Flip_exp6 = Bezier_Float ()
Flip_exp7 = Bezier_Float ()
MasCtrl.FlipControl.flip.controller = Bezier_Float ()
MasCtrl.FlipControl.shuffle.controller = Bezier_Float ()
MasCtrl.FlipControl.multiplier.controller = Bezier_Float ()
MasCtrl.FlipControl.turnAngle.controller=bezier_float()
MasCtrl.FlipControl.flexAngle.controller=bezier_float()
MasCtrl.FlipControl.landAngle.controller=bezier_float()

ec=linear_float()
with animate on
(
at time 0 ec.value=0
at time 100 ec.value=100*ticksPerFrame
)
setBeforeORT ec #linear
setAfterORT ec #linear



for i = 1 to page_list_array.count do
	(
	deger=4800/framerate
	dongu = (4800/framerate)*15
	pageCount=page_list_array.count
	pageExpVal=("(PageValue*(PageMultip))*"+(dongu as string)+"+"+(((pageCount-i)*dongu)-(pageCount*dongu))as string)+"+(PageShuffle*"+((i*deger) as string)+")"
	--pageExpVal=("T")
	pageExp=float_expression()
	pageExp.AddScalarTarget "PageValue" MasCtrl.FlipControl.flip.controller
	pageExp.AddScalarTarget "PageShuffle" MasCtrl.FlipControl.shuffle.controller
	pageExp.AddScalarTarget "PageMultip" MasCtrl.FlipControl.multiplier.controller
	
	--page_list_array[i].parent=MasCtrl
	addeasecurve page_list_array[i].modifiers["Flexer"].bendAngle.controller Flip_exp

	page_list_array[i].modifiers["Flexer"].bendAngle.controller[1].controller = pageExp
	page_list_array[i].modifiers["Flexer"].bendAngle.controller[1].controller.setExpression pageExpVal

		
	addeasecurve page_list_array[i].modifiers["Turner"].gizmo.position.x_position.controller Flip_exp7

	page_list_array[i].modifiers["Turner"].gizmo.position.x_position.controller[1].controller = pageExp
	page_list_array[i].modifiers["Turner"].gizmo.position.x_position.controller[1].controller.setExpression pageExpVal

		
	addeasecurve page_list_array[i].modifiers["Lander"].bendAngle.controller Flip_exp3

	page_list_array[i].modifiers["Lander"].bendAngle.controller[1].controller = pageExp
	page_list_array[i].modifiers["Lander"].bendAngle.controller[1].controller.setExpression pageExpVal


	addeasecurve page_list_array[i].modifiers["Turner"].bendAngle.controller Flip_exp2

	page_list_array[i].modifiers["Turner"].bendAngle.controller[1].controller = pageExp
	page_list_array[i].modifiers["Turner"].bendAngle.controller[1].controller.setExpression pageExpVal

		
		
	addeasecurve page_list_array[i].modifiers["Turner"].bendTo.controller Flip_exp4

	page_list_array[i].modifiers["Turner"].bendTo.controller[1].controller = pageExp
	page_list_array[i].modifiers["Turner"].bendTo.controller[1].controller.setExpression pageExpVal

	
	addeasecurve page_list_array[i].modifiers["Turner"].gizmo.rotation.z_rotation.controller Flip_exp5

	page_list_array[i].modifiers["Turner"].gizmo.rotation.z_rotation.controller[1].controller = pageExp
	page_list_array[i].modifiers["Turner"].gizmo.rotation.z_rotation.controller[1].controller.setExpression pageExpVal


	

	--addeasecurve page_list_array[i].rotation.y_rotation.controller Flip_exp5
	--framerate*(39.1/30)

		
	--V4.0 Change
	page_list_array[i].modifiers["Edge"].scale.controller=bezier_float()
	paramWire.connect MasCtrl.baseObject.FlipControl[#EdgeRandFq] page_list_array[i].modifiers[#Edge][#Scale] "EdgeRandFq"
	page_list_array[i].modifiers["Edge"].strength.controller=Point3_XYZ()
	paramWire.connect MasCtrl.baseObject.FlipControl[#EdgeRandVal] page_list_array[i].modifiers[#Edge].strength.controller[#X] "EdgeRandVal"
	paramWire.connect MasCtrl.baseObject.FlipControl[#EdgeRandVal] page_list_array[i].modifiers[#Edge].strength.controller[#Y] "EdgeRandVal"
	
	page_list_array[i].modifiers["Age"].scale.controller=bezier_float()
	paramWire.connect MasCtrl.baseObject.FlipControl[#OldnessFq] page_list_array[i].modifiers[#Age][#Scale] "OldnessFq"
	page_list_array[i].modifiers["Age"].strength.controller=Point3_XYZ()
	paramWire.connect MasCtrl.baseObject.FlipControl[#OldnessVal] page_list_array[i].modifiers[#Age].strength.controller[#Z] "OldnessVal"
	----------------------------------------------------------
	
	--multiplier	
		
		--FLEXER
	paramWire.connect MasCtrl.FlipControl[#Flex_CCenter] page_list_array[i].modifiers["Flexer"].center.controller[1] "Flex_CCenter"
	page_list_array[i].modifiers["Flexer"].bendTo.controller=bezier_float()
	paramWire.connect MasCtrl.FlipControl[#Flex_CArea] page_list_array[i].modifiers["Flexer"][#UpperLimit] "Flex_CArea"
	paramWire.connect MasCtrl.FlipControl[#Turn_CCenter] page_list_array[i].modifiers["Turner"].center.controller[1] ("-($"+MasCtrl.name+".pageWidth/2-Turn_CCenter)")
		--LANDER
	paramWire.connect MasCtrl.FlipControl[#Land_CCenter] page_list_array[i].modifiers[#Lander].Center.controller[#X_Position] ("(Land_CCenter)")
	paramWire.connect MasCtrl.FlipControl[#Land_CArea] page_list_array[i].modifiers[#Lander][#UpperLimit] "Land_CArea"
	

	paramWire.connect MasCtrl.FlipControl[#lengthsegs] page_list_array[i].baseobject[#Length_Segments] "lengthsegs"
	paramWire.connect MasCtrl.FlipControl[#widthsegs] page_list_array[i].baseobject[#Width_Segments] "widthsegs"

	page_list_array[i].modifiers["Turner"].bendTo.controller=float_list()-- Ekstra Upper Limit Ayari icin YERI ONEMLI
	page_list_array[i].modifiers["Turner"].bendTo.controller.available.controller=bezier_float() -- Ekstra Upper Limit Controller
	page_list_array[i].modifiers["Turner"].bendTo.controller.available.controller=bezier_float()
	page_list_array[i].modifiers["Turner"].bendTo.controller.active = 3 -- Yeni controlleri aktif kontrolcu yap

	paramWire.connect MasCtrl.FlipControl[#extraCrease] page_list_array[i].modifiers["Turner"].BendTo.controller[2] "extraCrease"

	--Bottom Angle icin
	page_list_array[i].modifiers["Turner"].bendAngle.controller=float_list()
	page_list_array[i].modifiers["Turner"].bendAngle.controller.available.controller=bezier_float()
	page_list_array[i].modifiers["Turner"].bendTo.controller.active = 2
	paramWire.connect MasCtrl.FlipControl[#BottomAngle] page_list_array[i].modifiers["Turner"].BendAngle.controller[2] "BottomAngle"
	paramWire.connect MasCtrl.FlipControl[#BottomAngle] page_list_array[i].rotation.controller[#Y_Rotation] "degtorad (-BottomAngle)"
	
	-- Flex Angle icin 
	----------------------------
	--BURAYA BAKILACAK--
	-----------------------------
	
	--Su anda asagidaki 3 satir multiplier fonksiyonunun calismasini engelliyor.
	page_list_array[i].modifiers["Flexer"].bendAngle.controller=float_list()
	page_list_array[i].modifiers["Flexer"].bendAngle.controller.available.controller=bezier_float()
	paramWire.connect MasCtrl.FlipControl[#extraFlex] page_list_array[i].modifiers["Flexer"].BendAngle.controller[2] "extraFlex"
	
	-- Land List controller
	page_list_array[i].modifiers["Lander"].bendAngle.controller=float_list()
	page_list_array[i].modifiers["Lander"].bendAngle.controller.available.controller=bezier_float()
	
	
	--------------------------------------------------------
	-----------TURN ANGLE CORRECTION------------
	--------------------------------------------------------
	
	
	turnAngleExp=float_expression()
	turnAngleExp.AddScalarTarget "TurnAngleCorrection" MasCtrl.FlipControl.turnAngle.controller
	turnAngleExpVal="1+degToRad(TurnAngleCorrection)"
	
	page_list_array[i].modifiers[#Turner].BendAngle.controller.weight[1].controller = turnAngleExp
	page_list_array[i].modifiers[#Turner].BendAngle.controller.weight[1].controller.setExpression turnAngleExpVal
	
	--------------------------------------------------------
	-----------FLEX ANGLE CORRECTION------------
	--------------------------------------------------------
	
	
	flexAngleExp=float_expression()
	flexAngleExp.AddScalarTarget "flexAngleCorrection" MasCtrl.FlipControl.flexAngle.controller
	flexAngleExpVal="1+degToRad(flexAngleCorrection)"
	
	page_list_array[i].modifiers[#flexer].BendAngle.controller.weight[1].controller = flexAngleExp
	page_list_array[i].modifiers[#flexer].BendAngle.controller.weight[1].controller.setExpression flexAngleExpVal
	
	--------------------------------------------------------
	-----------LAND ANGLE CORRECTION------------
	--------------------------------------------------------
	
	
	landAngleExp=float_expression()
	landAngleExp.AddScalarTarget "landAngleCorrection" MasCtrl.FlipControl.landAngle.controller
	landAngleExpVal="1+degToRad(landAngleCorrection)"
	
	page_list_array[i].modifiers[#lander].BendAngle.controller.weight[1].controller = landAngleExp
	page_list_array[i].modifiers[#lander].BendAngle.controller.weight[1].controller.setExpression landAngleExpVal
	
	
	)

)

)--End of PageRig Function



/* ===== tail: only launch UI if licensed ===== */

try(destroyDialog PRigv3)catch()

if BR_Licensing.ensureActivated() do
(
    Fw1 = 30
    Fw2 = 30

    rollout PRigv3 "Book Rigger V3.5" width:292 height:454
    (
        spinner pageCountSP "Page Count" type:#integer range:[1,99999,50]
        button pageRigBT "Rig the Book"
        label licenseINF0 "Licensed To:"
        label licenseINF1 "Unknown"

        on PRigv3 open do
        (
            if BR_Licensing.LicensedEmail != "" do licenseINF1.text = BR_Licensing.LicensedEmail
        )

        on pageRigBT pressed do
        (
            -- your existing function
            pageRig pageCountSP.value
        )
    )

    createDialog PRigv3 160 90
)
)
