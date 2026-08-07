class Staff {
  final String staffId;
  final String name;
  final String role; // "doctor", "nurse", "admin"
  final List<String> assignedRooms;

  Staff({
    required this.staffId,
    required this.name,
    required this.role,
    this.assignedRooms = const [],
  });

  factory Staff.fromMap(Map<String, dynamic> data, String documentId) {
    return Staff(
      staffId: documentId,
      name: data['name'] ?? '',
      role: data['role'] ?? 'nurse',
      assignedRooms: List<String>.from(data['assignedRooms'] ?? []),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'role': role,
      'assignedRooms': assignedRooms,
    };
  }
}
