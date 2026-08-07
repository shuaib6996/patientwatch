import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/patient.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({Key? key}) : super(key: key);

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _formKey = GlobalKey<FormState>();
  String _name = '';
  String _roomNumber = '';
  String _bedNumber = '';
  String _deviceId = '';
  bool _isLoading = false;

  Future<void> _submit() async {
    if (_formKey.currentState!.validate()) {
      _formKey.currentState!.save();
      
      setState(() => _isLoading = true);

      final docRef = FirebaseFirestore.instance.collection('patients').doc();
      final patient = Patient(
        patientId: docRef.id,
        name: _name,
        roomNumber: _roomNumber,
        bedNumber: _bedNumber,
        deviceId: _deviceId,
        status: true,
        admittedAt: DateTime.now(),
      );

      await docRef.set(patient.toMap());
      
      if (mounted) {
        setState(() => _isLoading = false);
        Navigator.pop(context);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Onboard Patient')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                decoration: const InputDecoration(labelText: 'Patient Alias / Bed Identifier'),
                validator: (v) => v!.isEmpty ? 'Required' : null,
                onSaved: (v) => _name = v!,
              ),
              TextFormField(
                decoration: const InputDecoration(labelText: 'Room Number'),
                validator: (v) => v!.isEmpty ? 'Required' : null,
                onSaved: (v) => _roomNumber = v!,
              ),
              TextFormField(
                decoration: const InputDecoration(labelText: 'Bed Number'),
                validator: (v) => v!.isEmpty ? 'Required' : null,
                onSaved: (v) => _bedNumber = v!,
              ),
              TextFormField(
                decoration: const InputDecoration(labelText: 'Device ID (Camera)'),
                validator: (v) => v!.isEmpty ? 'Required' : null,
                onSaved: (v) => _deviceId = v!,
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _isLoading ? null : _submit,
                child: _isLoading ? const CircularProgressIndicator() : const Text('Save Patient'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
