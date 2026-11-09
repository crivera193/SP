import 'package:campus_app/teams/game_team.dart';
import 'package:flutter/material.dart';

const healthScience = GameTeam(
  id: 'health_science',
  displayName: 'Health and Science',
  colorName: 'Blue',
  color: Color(0xff77bfff),
  description:
      'Stay curious. Explore life, wellbeing and the world around you.',
);
const mathEngineering = GameTeam(
  id: 'math_engineering',
  displayName: 'Math and Engineering',
  colorName: 'Red',
  color: Color(0xffff9292),
  description:
      'Think boldly. Find patterns, solve puzzles and build new possibilities.',
);
const artStuff = GameTeam(
  id: 'art_stuff',
  displayName: 'Art and Stuff',
  colorName: 'Yellow',
  color: Color(0xffffdf7b),
  description:
      'Make your mark. Bring imagination, expression and a fresh perspective.',
);
const testTeams = [healthScience, mathEngineering, artStuff];
