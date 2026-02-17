workbenchDefs = {
    ["chem_table_v1"] = {
        modelName = "chem_table_v1",
        itemId = 758, -- <-- IMPORTANT: what item you get back on pickup
    }
}

function getWorkbenchModelName(benchType)
    return workbenchDefs[benchType] and workbenchDefs[benchType].modelName or nil
end

function getWorkbenchItemId(benchType)
    return workbenchDefs[benchType] and workbenchDefs[benchType].itemId or nil
end