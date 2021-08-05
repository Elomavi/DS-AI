KiteMaster = Class(BehaviourNode, function(self, inst, max_chase_time, give_up_dist, max_attacks, findnewtargetfn, walk)
    BehaviourNode._ctor(self, "KiteMaster")
    self.inst = inst
    self.findnewtargetfn = findnewtargetfn
    self.max_chase_time = max_chase_time
    self.give_up_dist = give_up_dist
    self.max_attacks = max_attacks
    self.numattacks = 0
    self.walk = walk
    
    -- we need to store this function as a key to use to remove itself later
    self.onattackfn = function(inst, data)
        self:OnAttackOther(data.target) 
    end

    self.inst:ListenForEvent("onattackother", self.onattackfn)
    self.inst:ListenForEvent("onmissother", self.onattackfn)
end)

function KiteMaster:__tostring()
    return string.format("target %s", tostring(self.inst.components.combat.target))
end

function KiteMaster:OnStop()
    self.inst:RemoveEventCallback("onattackother", self.onattackfn)
    self.inst:RemoveEventCallback("onmissother", self.onattackfn)
end

function KiteMaster:OnAttackOther(target)
    --print ("on attack other", target)
    self.numattacks = self.numattacks + 1
    self.startruntime = nil -- reset max chase time timer
end

function KiteMaster:GetRunAngle(pt, hp)

    if self.avoid_angle then
        local avoid_time = GetTime() - self.avoid_time
        if avoid_time < 1 then
            return self.avoid_angle
        else
            self.avoid_time = nil
            self.avoid_angle = nil
        end
    end

    local angle = self.inst:GetAngleToPoint(hp) + 180 -- + math.random(30)-15
    if angle > 360 then angle = angle - 360 end

    --print(string.format("RunAway:GetRunAngle me: %s, hunter: %s, run: %2.2f", tostring(pt), tostring(hp), angle))

    if self.inst.CheckIsInInterior and  self.inst:CheckIsInInterior() then 
        -- deflect run away angle towards center
        local is = GetWorld().components.interiorspawner
        local spt = is:getSpawnOrigin()

        local centangle = self.inst:GetAngleToPoint(spt.x,spt.y,spt.z)
        local diff = 180 - math.abs(math.abs(centangle - angle) - 180) --  centangle - angle
        if diff > 180 then 
            diff = 360 - diff 
        end

        if diff > 90 or diff < -90 then
            if centangle - angle > 180 or centangle - angle < -180 then
                angle = centangle - 90 
            else
                angle = centangle + 90 
            end
        end
        if angle > 360 then angle = angle - 360 end
        if angle < 0 then angle = angle +  360 end

        return angle
    else
    	local radius = 6

        local result_offset, result_angle, deflected = FindWalkableOffset(pt, angle*DEGREES, radius, 8, true, false) -- try avoiding walls
        if not result_angle then
            result_offset, result_angle, deflected = FindWalkableOffset(pt, angle*DEGREES, radius, 8, true, true) -- ok don't try to avoid walls, but at least avoid water
        end
        if not result_angle then
            return angle -- ok whatever, just run
        end

    	if result_angle then
    		result_angle = result_angle/DEGREES
    		if deflected then
    			self.avoid_time = GetTime()
    			self.avoid_angle = result_angle
    		end
    		return result_angle
    	end
    end

    return nil
end

function KiteMaster:Visit()
    
    local combat = self.inst.components.combat
    if self.status == READY then
        
        -- Make sure our target is still valid
        combat:ValidateTarget()
        
        if not combat.target and self.findnewtargetfn then
            combat.target = self.findnewtargetfn(self.inst)
        end
        
        -- Time to die
        if combat.target then
            print("Declared war on " .. combat.target.prefab )
            self.inst.components.combat:BattleCry()
            self.startruntime = GetTime()
            self.numattacks = 0
            self.status = RUNNING
        else
            self.status = FAILED
        end
        
    end

    if self.status == RUNNING then
        -- local is_attacking = self.inst.sg:HasStateTag("attack")

        if not combat.target or not combat.target:IsValid() then
            self.status = FAILED
            combat:SetTarget(nil)
            self.inst.components.locomotor:Stop()
            return
        end
        if combat.target.components.health and combat.target.components.health:IsDead() then
            self.status = SUCCESS
            combat:SetTarget(nil)
            self.inst.components.locomotor:Stop()
            return
        end

        -- We know our movement speed and their attack range. 
        -- Calculate how long it will take to get out of attack range. 
        -- The, start moving that long before their next attack.
        local otherCombat = combat.target.components.combat
        local attackRange = otherCombat:GetAttackRange() -- How close we need to be to bait attack
        local ar2 = attackRange * attackRange
        --local attackRange = otherCombat:CalcAttackRangeSq()
        local hitRange = otherCombat:GetHitRange() or 1-- How close we need to be to be hit by attack
        local hr2 = hitRange * hitRange
        --local hitRange = otherCombat:CalcHitRangeSq() or 1 -- How close (in distance) they can hit us
        local inCooldown = otherCombat:InCooldown()
        local weAreTarget = otherCombat.target and (otherCombat.target == self.inst) or false
        local timeToNextAttack = 0
        if inCooldown then
            local is_attacking = (combat.target.sg and combat.target.sg:HasStateTag("attack")) or false
            if is_attacking then
                -- Wait for the attack animation to finish
                --print("They are attacking!")
                timeToNextAttack = 0
            else
                local time_since_doattack = GetTime() - otherCombat.laststartattacktime
                timeToNextAttack = otherCombat.min_attack_period - time_since_doattack
            end
        end

        -- If they are taunting us, ignore their next move
        if combat.target and combat.target.sg then
            if combat.target.sg:HasStateTag("taunt") or combat.target.sg:HasStateTag("sleeping") or combat.target.sg:HasStateTag("hit") or 
                (combat.target.sg:HasStateTag("busy") and not combat.target.sg:HasStateTag("attack")) then
                timeToNextAttack = 3
            end
        end

        --print("Target state tag: " .. tostring(combat.target.sg))

        -- How long will it take us to move out of the way
        -- TODO: This assumes we don't change speed (path, spider webs, etc)
        local runSpeed = self.inst.components.locomotor:GetRunSpeed()

        local dt = 0.125/4.0

        -- Assume units are all the same? Can we got runSpeed distance each tick?
        -- Locomotor has this in there...
        --     local run_dist = self:GetRunSpeed()*dt*.5
        --     Is game speed relative to frames/second (30)? Above func implies you run X/2 every tick. or 2 ticks to go x. 
        local run_dist = runSpeed * dt -- how far we run each tick
        local rd2 = run_dist * run_dist
        --print("We run " .. run_dist .. " each tick")
        local timeToClearAttack = run_dist / hitRange / runSpeed
        

        -- If time to clear attack > time to next attack, just keep whacking away. 

        
        local hp = Point(combat.target.Transform:GetWorldPosition())
        local pt = Point(self.inst.Transform:GetWorldPosition())
        local dsq = distsq(hp, pt)
        local angle = self.inst:GetAngleToPoint(hp)
        local r = self.inst.Physics:GetRadius() + (combat.target.Physics and combat.target.Physics:GetRadius() + .1 or 0)
        local running = self.inst.components.locomotor:WantsToRun()

        -- Can tell if they are in the middle of attack
        --local enemy_attacking = combat.target.sg:HasStateTag("attack")

        -- Take our current distance from the target, subtract their hit range. That is how far we are from safety. 
        local physicalDist = (r*r) + (hr2) + (hr2)/4
        local distToSafety = (physicalDist - dsq)
        local timeToSafety = (distToSafety / ((runSpeed) / dt)) - 0.2
        

        -- dsq is distance to enemy
        --print("We are " .. tostring(dsq) .. " away from enemy")
        --print("We are " .. tostring(physicalDist) .. " away from safe distance")
        --print("They have attack range of " .. tostring(ar2))
        --print("They have hit range of " .. tostring(hr2))
        --print("Are we the target? " .. tostring(weAreTarget))
        --print("It will take " .. tostring(timeToSafety) .. " seconds to clear the attack and they attack in " .. tostring(timeToNextAttack) .. " seconds")

        
        -- If they can attack, and we are inside the attack radius, do this.
        if(weAreTarget and ( timeToSafety >= (timeToNextAttack)) ) then
            --print("Time to kite")
            -- Get to the very edge of their attack range. Add their physical model size to this range. 
            local baitDist = physicalDist
            --print("Bait distance " .. tostring(baitDist))
            --print("Current distance " .. tostring(dsq))
            if (dsq <= baitDist) then
                --print("duck dodge dip dive dodge")
                -- Run away from them until they attack
                local shouldRun = not self.walk
                self.inst.components.locomotor:RunInDirection(self:GetRunAngle(pt, hp))

                -- Re-evaluate in dt seconds
                self:Sleep(dt)
                return
            else
                -- We are far enough away...just let wilson go try to attack like normal to get closer. 
                self:Sleep(dt)
                return
            end
        end
            
        if (running and dsq > r*r) or (not running and dsq > combat:CalcAttackRangeSq() ) then
            --self.inst.components.locomotor:RunInDirection(angle)
            local shouldRun = not self.walk
            self.inst.components.locomotor:GoToPoint(hp, nil, shouldRun)
        elseif not (self.inst.sg and self.inst.sg:HasStateTag("jumping")) then
            self.inst.components.locomotor:Stop()
            if self.inst.sg:HasStateTag("canrotate") then
                self.inst:FacePoint(hp)
            end                
        end
                
        if combat:TryAttack() then
            -- reset chase timer when attack hits, not on attempts
        else
            if not self.startruntime then
                self.startruntime = GetTime()
                self.inst.components.combat:BattleCry()
            end
        end

            
        -- if self.max_attacks and self.numattacks >= self.max_attacks then
        --     self.status = SUCCESS
        --     self.inst.components.combat:SetTarget(nil)
        --     self.inst.components.locomotor:Stop()
        --     return
        -- end
        
        -- if self.give_up_dist then
        --     if dsq >= self.give_up_dist*self.give_up_dist then
        --         self.status = FAILED
        --         self.inst.components.combat:GiveUp()
        --         self.inst.components.locomotor:Stop()
        --         return
        --     end
        -- end
        
        -- if self.max_chase_time and self.startruntime then
        --     local time_running = GetTime() - self.startruntime
        --     if time_running > self.max_chase_time then
        --         self.status = FAILED
        --         self.inst.components.combat:GiveUp()
        --         self.inst.components.locomotor:Stop()
        --         return
        --     end
        -- end
        self:Sleep(dt)
        
    end
end