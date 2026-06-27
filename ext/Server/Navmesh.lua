---@class Navmesh
---@overload fun():Navmesh
Navmesh = class('Navmesh')

-- =============================================================================
-- Navmesh persistence + query (server side).
--
-- The heavy lifting (world probing via raycasts) happens on the client in
-- ClientNavmeshBaker, because VU only exposes raycasting client-side. This module
-- receives the baked cells over NetEvents, persists them into the mod database in
-- a per-map table (mirroring how NodeCollection stores traces), loads them back on
-- level load, and exposes a small lookup API that the bot AI can use later as the
-- tactical navigation layer.
--
-- Table layout: <Level>_<GameMode>_navmesh
--   gx, gz, gy : integer grid coordinates (gy separates stacked surfaces)
--   x,  y,  z  : world-space cell centre / floor height
-- =============================================================================

require('__shared/Config')

---@type Logger
local m_Logger = Logger('Navmesh', Debug.Server.NODEEDITOR)

function Navmesh:__init()
	self:RegisterVars()
end

function Navmesh:RegisterVars()
	-- Current map identifier, e.g. "MP_001_ConquestSmall0".
	self.m_MapName = ''
	-- Cell size the loaded/active mesh was baked at.
	self.m_CellSize = Registry.NAVMESH.CELL_SIZE

	-- In-memory mesh: key "gx:gz:gy" -> { x, y, z }. Used for runtime queries.
	self.m_Cells = {}
	self.m_CellCount = 0

	-- Streaming-save state. Batches are written to the database as they arrive (across
	-- many frames), so a large mesh never stalls the server in a single tick.
	self.m_SaveInProgress = false
	self.m_SaveOk = true
	self.m_IncomingCount = 0
	self.m_IncomingCellSize = Registry.NAVMESH.CELL_SIZE
	self.m_SaveTable = ''

	-- Streaming-load state (server -> client) used by the editor. The in-memory mesh is
	-- flattened and sent in throttled batches so it never floods the client.
	self.m_LoadSending = false
	self.m_LoadPlayerId = nil
	self.m_LoadQueue = {}
	self.m_LoadCursor = 1
	self.m_LoadTimer = 0.0
end

-- =============================================
-- Events
-- =============================================

function Navmesh:RegisterCustomEvents()
	NetEvents:Subscribe('Navmesh:StoreBegin', self, self.OnStoreBegin)
	NetEvents:Subscribe('Navmesh:StoreBatch', self, self.OnStoreBatch)
	NetEvents:Subscribe('Navmesh:StoreCommit', self, self.OnStoreCommit)
	NetEvents:Subscribe('Navmesh:RequestLoad', self, self.OnRequestLoad)
end

-- =============================================
-- Load (server -> client) for the editor
-- =============================================

-- A client (editor) asks for the current navmesh. Flatten the in-memory mesh and stream
-- it back in throttled batches from OnUpdate.
---@param p_Player Player
function Navmesh:OnRequestLoad(p_Player)
	if not self:_IsAuthorized(p_Player) then
		return
	end

	self.m_LoadQueue = {}
	for l_Key, l_Cell in pairs(self.m_Cells) do
		local s_Parts = l_Key:split(':') -- "gx:gz:gy"
		self.m_LoadQueue[#self.m_LoadQueue + 1] = {
			gx = tonumber(s_Parts[1]),
			gz = tonumber(s_Parts[2]),
			gy = tonumber(s_Parts[3]),
			x = l_Cell.x,
			y = l_Cell.y,
			z = l_Cell.z,
		}
	end

	self.m_LoadCursor = 1
	self.m_LoadPlayerId = p_Player.onlineId
	self.m_LoadSending = true
	self.m_LoadTimer = 0.0

	NetEvents:SendTo('Navmesh:LoadBegin', p_Player, { cellSize = self.m_CellSize, total = #self.m_LoadQueue })
	m_Logger:Write('Navmesh editor load: streaming ' .. tostring(#self.m_LoadQueue) .. ' cells to ' .. p_Player.name)
end

-- Drive the streaming load. Called every server engine update.
---@param p_DeltaTime number
function Navmesh:OnUpdate(p_DeltaTime)
	if not self.m_LoadSending then
		return
	end

	-- Resolve the target each tick so a player leaving mid-stream aborts cleanly.
	local s_Player = self.m_LoadPlayerId and PlayerManager:GetPlayerByOnlineId(self.m_LoadPlayerId) or nil
	if s_Player == nil then
		self.m_LoadSending = false
		self.m_LoadQueue = {}
		return
	end

	self.m_LoadTimer = self.m_LoadTimer + p_DeltaTime
	if self.m_LoadTimer < Registry.NAVMESH.LOAD_SEND_INTERVAL then
		return
	end
	self.m_LoadTimer = 0.0

	local s_BatchSize = Registry.NAVMESH.STORE_BATCH_SIZE
	for _ = 1, Registry.NAVMESH.LOAD_BATCHES_PER_TICK do
		if self.m_LoadCursor > #self.m_LoadQueue then
			NetEvents:SendTo('Navmesh:LoadCommit', s_Player)
			self.m_LoadSending = false
			self.m_LoadQueue = {}
			m_Logger:Write('Navmesh editor load complete.')
			return
		end

		local s_Batch = {}
		for _ = 1, s_BatchSize do
			local l_Cell = self.m_LoadQueue[self.m_LoadCursor]
			if l_Cell == nil then
				break
			end
			s_Batch[#s_Batch + 1] = l_Cell
			self.m_LoadCursor = self.m_LoadCursor + 1
		end
		NetEvents:SendTo('Navmesh:LoadBatch', s_Player, s_Batch)
	end
end

---@param p_LevelName string
---@param p_GameMode string
function Navmesh:OnLevelLoaded(p_LevelName, p_GameMode)
	self.m_MapName = (p_LevelName .. '_' .. p_GameMode):gsub(' ', '_')
	self:Load()
end

function Navmesh:OnLevelDestroy()
	self.m_Cells = {}
	self.m_CellCount = 0
	self.m_IncomingCount = 0
	self.m_SaveInProgress = false
	self.m_LoadSending = false
	self.m_LoadPlayerId = nil
	self.m_LoadQueue = {}
end

-- =============================================
-- Save (client -> server -> database)
-- =============================================

-- Begin a streaming save: (re)create the table. Each batch is written as it arrives.
---@param p_Player Player
---@param p_Info table @{ cellSize, total }
function Navmesh:OnStoreBegin(p_Player, p_Info)
	if not self:_IsAuthorized(p_Player) then
		return
	end

	if self.m_MapName == '' then
		m_Logger:Error('Cannot save navmesh: map name not set.')
		return
	end

	self.m_IncomingCount = 0
	self.m_IncomingCellSize = (p_Info and p_Info.cellSize) or Registry.NAVMESH.CELL_SIZE
	self.m_SaveTable = self.m_MapName .. '_navmesh'
	self.m_SaveOk = true
	self.m_SaveInProgress = true

	-- (Re)create the table up front. Each insert below opens/closes its own short SQL
	-- session, so the database handle is never held across frames.
	if not SQL:Open() then
		m_Logger:Error('Failed to open SQL on save begin: ' .. SQL:Error())
		self.m_SaveInProgress = false
		return
	end

	SQL:Query('DROP TABLE IF EXISTS ' .. self.m_SaveTable)
	local s_Create = [[
		CREATE TABLE IF NOT EXISTS ]] .. self.m_SaveTable .. [[ (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		gx INTEGER, gz INTEGER, gy INTEGER,
		x FLOAT, y FLOAT, z FLOAT
		)
	]]
	if not SQL:Query(s_Create) then
		m_Logger:Error('Failed to create navmesh table: ' .. SQL:Error())
		self.m_SaveOk = false
		self.m_SaveInProgress = false
	end
	SQL:Close()

	m_Logger:Write('Navmesh save started for ' .. self.m_MapName ..
		' (expecting ' .. tostring((p_Info and p_Info.total) or '?') .. ' cells)')
end

-- Write one batch straight to the database. Because the client streams batches across
-- many frames, these inserts are naturally spread out and never stall the server.
---@param p_Player Player
---@param p_Batch table[]
function Navmesh:OnStoreBatch(p_Player, p_Batch)
	if not self.m_SaveInProgress or not self:_IsAuthorized(p_Player) then
		return
	end

	if #p_Batch == 0 then
		return
	end

	local s_Values = {}
	for l_Index = 1, #p_Batch do
		local l_Cell = p_Batch[l_Index]
		s_Values[#s_Values + 1] = string.format('(%d,%d,%d,%f,%f,%f)',
			l_Cell.gx, l_Cell.gz, l_Cell.gy, l_Cell.x, l_Cell.y, l_Cell.z)
	end

	if not SQL:Open() then
		m_Logger:Error('Failed to open SQL on save batch: ' .. SQL:Error())
		self.m_SaveOk = false
		return
	end

	local s_Query = 'INSERT INTO ' .. self.m_SaveTable ..
		' (gx, gz, gy, x, y, z) VALUES ' .. table.concat(s_Values, ',')

	if not SQL:Query(s_Query) then
		m_Logger:Error('Failed to insert navmesh batch: ' .. SQL:Error())
		self.m_SaveOk = false
	else
		self.m_IncomingCount = self.m_IncomingCount + #p_Batch
	end

	SQL:Close()
end

-- Finish the streaming save: write the meta table and report the result.
---@param p_Player Player
function Navmesh:OnStoreCommit(p_Player)
	if not self.m_SaveInProgress or not self:_IsAuthorized(p_Player) then
		return
	end

	self.m_SaveInProgress = false

	if self.m_SaveOk and SQL:Open() then
		local s_MetaTable = self.m_MapName .. '_navmesh_meta'
		SQL:Query('DROP TABLE IF EXISTS ' .. s_MetaTable)
		SQL:Query('CREATE TABLE IF NOT EXISTS ' .. s_MetaTable .. ' (cellSize FLOAT, cellCount INTEGER)')
		SQL:Query('INSERT INTO ' .. s_MetaTable .. ' (cellSize, cellCount) VALUES (' ..
			tostring(self.m_IncomingCellSize) .. ', ' .. tostring(self.m_IncomingCount) .. ')')
		SQL:Close()
	end

	if self.m_SaveOk then
		m_Logger:Write('Navmesh saved: ' .. tostring(self.m_IncomingCount) .. ' cells for ' .. self.m_MapName)
		ChatManager:SendMessage('Navmesh saved: ' .. tostring(self.m_IncomingCount) ..
			' cells. It will be used from the next round (or after a level reload).', p_Player)
	else
		m_Logger:Error('Navmesh save failed for ' .. self.m_MapName)
		ChatManager:SendMessage('Navmesh save FAILED, see server log.', p_Player)
	end

	-- The mesh is now in the database; it is picked up by Load() on the next level load.
	-- We intentionally do not bulk-load 100k+ rows into memory here to avoid a stall,
	-- and there is no runtime consumer yet this session.
	self.m_IncomingCount = 0
end

-- =============================================
-- Load (database -> memory)
-- =============================================

function Navmesh:Load()
	self.m_Cells = {}
	self.m_CellCount = 0

	if self.m_MapName == '' then
		return
	end

	if not SQL:Open() then
		m_Logger:Error('Failed to open SQL on navmesh load: ' .. SQL:Error())
		return
	end

	local s_Table = self.m_MapName .. '_navmesh'
	local s_Exists = SQL:Query("select name from sqlite_master where type='table' and name='" .. s_Table .. "'")
	if not s_Exists or #s_Exists == 0 then
		-- No navmesh baked for this map yet; perfectly normal.
		SQL:Close()
		return
	end

	-- Recover the cell size from the meta table if present.
	local s_Meta = SQL:Query('SELECT cellSize FROM ' .. self.m_MapName .. '_navmesh_meta LIMIT 1')
	if s_Meta and #s_Meta > 0 and s_Meta[1]['cellSize'] then
		self.m_CellSize = s_Meta[1]['cellSize']
	end

	local s_Results = SQL:Query('SELECT gx, gz, gy, x, y, z FROM ' .. s_Table)
	if not s_Results then
		m_Logger:Error('Failed to load navmesh: ' .. SQL:Error())
		SQL:Close()
		return
	end

	for l_Index = 1, #s_Results do
		local l_Row = s_Results[l_Index]
		local s_Key = l_Row['gx'] .. ':' .. l_Row['gz'] .. ':' .. l_Row['gy']
		if self.m_Cells[s_Key] == nil then
			self.m_Cells[s_Key] = { x = l_Row['x'], y = l_Row['y'], z = l_Row['z'] }
			self.m_CellCount = self.m_CellCount + 1
		end
	end

	SQL:Close()
	m_Logger:Write('Loaded navmesh for ' .. self.m_MapName .. ': ' .. tostring(self.m_CellCount) .. ' cells.')
end

-- =============================================
-- Query API (foundation for the runtime tactical layer)
-- =============================================

---@return boolean
function Navmesh:HasMesh()
	return self.m_CellCount > 0
end

-- Return the walkable cell nearest to a world position, searching the local
-- 3x3 column and the two vertical neighbours. Returns { x, y, z } or nil.
---@param p_Position Vec3
---@return table|nil
function Navmesh:GetCellAt(p_Position)
	if self.m_CellCount == 0 then
		return nil
	end

	local s_Gx = math.floor(p_Position.x / self.m_CellSize)
	local s_Gz = math.floor(p_Position.z / self.m_CellSize)
	local s_Gy = math.floor(p_Position.y / Registry.NAVMESH.VERTICAL_RESOLUTION)

	local s_Best = nil
	local s_BestDy = nil

	for l_Dx = -1, 1 do
		for l_Dz = -1, 1 do
			for l_Dy = -1, 1 do
				local s_Key = (s_Gx + l_Dx) .. ':' .. (s_Gz + l_Dz) .. ':' .. (s_Gy + l_Dy)
				local s_Cell = self.m_Cells[s_Key]
				if s_Cell ~= nil then
					local s_Dy = math.abs(s_Cell.y - p_Position.y)
					if s_BestDy == nil or s_Dy < s_BestDy then
						s_BestDy = s_Dy
						s_Best = s_Cell
					end
				end
			end
		end
	end

	return s_Best
end

---@param p_Position Vec3
---@return boolean
function Navmesh:IsWalkable(p_Position)
	return self:GetCellAt(p_Position) ~= nil
end

-- =============================================
-- Helpers
-- =============================================

-- Only allow editor-privileged players to write the navmesh.
---@param p_Player Player
---@return boolean
function Navmesh:_IsAuthorized(p_Player)
	if p_Player == nil then
		return false
	end

	if PermissionManager == nil then
		return true
	end

	-- Same privilege the trace editor uses to write waypoints.
	return PermissionManager:HasPermission(p_Player, 'UserInterface.WaypointEditor.SaveLoad')
end

if g_Navmesh == nil then
	---@type Navmesh
	g_Navmesh = Navmesh()
end

return g_Navmesh
