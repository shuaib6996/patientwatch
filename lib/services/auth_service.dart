import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // Note: Enable Email/Password authentication in Firebase Console

  Future<User?> signInWithEmail(String email, String password) async {
    try {
      UserCredential credential = await _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
      return credential.user;
    } on FirebaseAuthException catch (e) {
      debugPrint("Auth Error: ${e.message}");
      throw Exception(e.message);
    } catch (e) {
      debugPrint("Unknown Auth Error: $e");
      throw Exception("An unknown error occurred");
    }
  }
  
  Future<User?> signUpWithEmail(String email, String password, String name) async {
    try {
      UserCredential credential = await _auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );
      
      if (credential.user != null) {
         await _firestore.collection('staff').doc(credential.user!.uid).set({
           'name': name,
           'email': email,
           'role': 'nurse',
           'assignedRooms': [],
         });
      }
      return credential.user;
    } on FirebaseAuthException catch (e) {
      debugPrint("Auth Error: ${e.message}");
      throw Exception(e.message);
    } catch (e) {
      debugPrint("Unknown Auth Error: $e");
      throw Exception("An unknown error occurred");
    }
  }

  Future<void> signOut() async {
    await _auth.signOut();
  }

  User? getCurrentUser() {
    return _auth.currentUser;
  }

  Stream<User?> authStateChanges() {
    return _auth.authStateChanges();
  }
}
