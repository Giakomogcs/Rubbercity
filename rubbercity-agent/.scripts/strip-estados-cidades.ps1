$path = "C:\Users\Administrador\Downloads\Zanaflex\zanaflex\front-zanaflex.html"
$enc  = New-Object System.Text.UTF8Encoding($false)
$lines = [System.IO.File]::ReadAllLines($path, $enc)

# 1-indexed boundaries (verified):
#   4990..5023 → IBGE_API + state + fetchEstados + fetchCidades  (REMOVE)
#   5024..5170 → buildMultiSelect (KEEP — reusable utility)
#   5171..5478 → msEstados/msCidades + init + onEstadosChanged + renderGroupedCidades + updateCidadesTrigger + getSelected*  (REMOVE)
#   5479..5497 → old formRoleSelect handler (REMOVE — no longer needed)
#   5498..EOF  → KEEP (let editingUserId = null; ...)

# Convert to 0-indexed slices
$prefix    = $lines[0..4988]              # lines 1..4989 (before IBGE_API)
$buildMS   = $lines[5023..5169]           # lines 5024..5170 (buildMultiSelect + surrounding blanks)
$suffix    = $lines[5497..($lines.Length-1)]  # lines 5498..EOF

# New replacement content: Teams/Categories admin helpers + Teams multi-select wiring
$newBlock = @'

      // ===== Teams & Categories admin layer (Zanaflex) =====
      // Replaces the estados/cidades geographic coverage model with a
      // team→category ACL model.

      let allTeams       = []; // [{id,name,description,member_ids:[], category_ids:[]}]
      let allCategories  = []; // [{id,code,name,description}]
      let selectedTeams  = []; // user form: team IDs the user belongs to

      async function fetchAllTeams() {
        try {
          const { data, error } = await supabaseClient.rpc(
            ZANAFLEX_PREFIX + "admin_list_teams"
          );
          if (error) throw error;
          allTeams = data || [];
        } catch (e) {
          allTeams = [];
        }
        return allTeams;
      }

      async function fetchAllCategories() {
        try {
          const { data, error } = await supabaseClient.rpc(
            ZANAFLEX_PREFIX + "list_categories"
          );
          if (error) throw error;
          allCategories = data || [];
        } catch (e) {
          allCategories = [];
        }
        return allCategories;
      }

      let msTeams = null;

      async function initFormMultiSelects() {
        // Reusable: build the team picker for the user form.
        const teams = await fetchAllTeams();
        msTeams = buildMultiSelect({
          triggerId: "teamsTrigger2",
          dropdownId: "teamsDropdown2",
          searchId:   "teamsSearch2",
          optionsId:  "teamsOptions2",
          items:      teams,
          selected:   selectedTeams,
          allLabel:   "Todas as equipes",
          allValue:   "__ALL__",
          onToggle:   () => {},
          renderLabel: (t) => t.name + (t.description ? " — " + t.description : ""),
        });
        if (msTeams) {
          msTeams.render("");
          msTeams.updateTrigger();
        }
      }

      function getSelectedTeamIds() {
        // buildMultiSelect stores either the special allValue or the rendered
        // label. We resolve back to UUIDs by matching on name.
        if (selectedTeams.includes("__ALL__")) {
          return allTeams.map((t) => t.id);
        }
        return selectedTeams
          .map((label) => {
            const name = label.split(" — ")[0];
            const t = allTeams.find((x) => x.name === name);
            return t ? t.id : null;
          })
          .filter(Boolean);
      }

      function setSelectedTeamsFromIds(ids) {
        selectedTeams.length = 0;
        (ids || []).forEach((id) => {
          const t = allTeams.find((x) => x.id === id);
          if (t) selectedTeams.push(t.name);
        });
      }

'@

$newLines = @()
$newLines += $prefix
$newLines += $buildMS
$newLines += ($newBlock -split "`r?`n")
$newLines += $suffix

[System.IO.File]::WriteAllLines($path, $newLines, $enc)
Write-Host ("Wrote {0} lines (was {1})" -f $newLines.Length, $lines.Length)
