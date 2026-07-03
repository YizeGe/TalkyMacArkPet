const fs = require('fs');
const { spawnSync } = require('child_process');
const path = require('path');

const profilesPath = path.join(__dirname, '../Resources/CharacterProfiles.json');
const dialoguesPath = path.join(__dirname, '../Resources/Dialogues.json');
const bakProfilesPath = path.join(__dirname, '../Resources/CharacterProfiles.json.bak');

const bundleProfilesPath = path.join(__dirname, '../release/MacArkPet.app/Contents/Resources/CharacterProfiles.json');
const bundleDialoguesPath = path.join(__dirname, '../release/MacArkPet.app/Contents/Resources/Dialogues.json');


const prtsProfilesPath = path.join(__dirname, '../Resources/AllOperatorsList.json');

if (!fs.existsSync(prtsProfilesPath)) {
  console.error('干员列表文件不存在，无法获取角色列表。');
  process.exit(1);
}

const allOperators = JSON.parse(fs.readFileSync(prtsProfilesPath, 'utf8'));
const currentProfiles = fs.existsSync(profilesPath) ? JSON.parse(fs.readFileSync(profilesPath, 'utf8')) : {};
const currentDialogues = fs.existsSync(dialoguesPath) ? JSON.parse(fs.readFileSync(dialoguesPath, 'utf8')) : {};

const args = process.argv.slice(2);
const flags = args.filter(a => a.startsWith('--'));
const nameArgs = args.filter(a => !a.startsWith('--'));

let charactersToGenerate = [];

if (nameArgs.length > 0) {
  // 指定生成特定角色
  charactersToGenerate = nameArgs;
} else if (flags.includes('--force') || flags.includes('--all')) {
  // 强制全部重生成
  charactersToGenerate = allOperators;
} else {
  // 默认增量生成：只生成未存在或失败的角色
  const existingNames = new Set(Object.values(currentProfiles).map(p => p.name || p.subtitle || p.id));
  charactersToGenerate = allOperators
    .filter(name => !existingNames.has(name) || !currentProfiles[name]);
}

if (charactersToGenerate.length === 0) {
  console.log('✅ 所有角色都已经生成完毕，无需重复生成！');
  process.exit(0);
}

console.log(`准备重新生成 ${charactersToGenerate.length} 个角色...`);

for (let i = 0; i < charactersToGenerate.length; i++) {
  const name = charactersToGenerate[i];
  console.log(`[${i + 1}/${charactersToGenerate.length}] 正在生成 ${name}...`);
  
  let pyArgs = [path.join(__dirname, '../agent/character_agent.py')];
  if (flags.includes('--no-ai')) {
    pyArgs.push('--no-ai');
  }
  pyArgs.push(name);
  
  const result = spawnSync('python3', pyArgs, {
    encoding: 'utf8'
  });

  if (result.error) {
    console.error(`❌ 生成 ${name} 时启动进程失败: ${result.error}`);
    continue;
  }

  const output = result.stdout || '';
  const stderr = result.stderr || '';
  
  const jsonStart = output.indexOf('{');
  const jsonEnd = output.lastIndexOf('}');
  
  if (jsonStart !== -1 && jsonEnd !== -1) {
    try {
      const jsonStr = output.substring(jsonStart, jsonEnd + 1);
      const generated = JSON.parse(jsonStr);
      
      const charId = generated.profile.id;
      currentProfiles[charId] = generated.profile;
      currentDialogues[charId] = generated.dialogues;
      
      // 每生成一个保存一次，防止中途崩溃
      fs.writeFileSync(profilesPath, JSON.stringify(currentProfiles, null, 2));
      fs.writeFileSync(dialoguesPath, JSON.stringify(currentDialogues, null, 2));
      
      try {
        if (fs.existsSync(bundleProfilesPath)) fs.writeFileSync(bundleProfilesPath, JSON.stringify(currentProfiles, null, 2));
        if (fs.existsSync(bundleDialoguesPath)) fs.writeFileSync(bundleDialoguesPath, JSON.stringify(currentDialogues, null, 2));
      } catch(e) {}
      
      console.log(`✅ ${name} 生成成功！`);
    } catch (e) {
      console.error(`❌ 生成 ${name} 时解析 JSON 失败: ${e.message}\n输出: ${output}\n错误信息: ${stderr}`);
    }
  } else {
    console.error(`❌ 生成 ${name} 失败，未找到合法的 JSON 返回。\n输出: ${output}\n错误信息: ${stderr}`);
  }
}

console.log('🎉 所有角色批量生成完毕！');
